#!/usr/bin/env python3
"""
RNS Bridge Daemon for LocalSend-Reticulum.

Communicates with the Flutter/Dart app via JSON lines over stdin/stdout.
Everything that is not a protocol message (RNS logs, stray prints) goes to stderr.

Commands (-> bridge):
  {"cmd": "init", "config_path": "...", "identity_path": "...", "staging_dir": "..."}
  {"cmd": "announce", "app_data": {"alias": "...", "version": "...", "device_model": "..."}}
  {"cmd": "send_session", "session_id": "...", "dest_hex": "<hex>", "files": [{"id","file_name","size","type","path"}]}
  {"cmd": "accept_session", "session_id": "...", "accepted_files": {"<file id>": "<name>"}}
  {"cmd": "decline_session", "session_id": "..."}
  {"cmd": "cancel_session", "session_id": "..."}
  {"cmd": "request_path", "dest_hex": "<hex>"}
  {"cmd": "get_peers"}
  {"cmd": "refresh"}   (user scan: replay cached peers + rate-limited announce)
  {"cmd": "get_interfaces"} / {"cmd": "configure_interfaces", "interfaces": [...]}
  {"cmd": "shutdown"}

Events (<- bridge). Session events carry "session_id" and "role" ("sender"/"receiver"):
  ready, peer_discovered, peer_list, announce_sent, session_connecting, session_established,
  session_request, session_accepted, session_declined, session_cancelled, transfer_progress,
  transfer_complete, transfer_failed, session_complete, session_error, link_closed, error

Network usage design:
  * One announce at startup, one every ANNOUNCE_INTERVAL, and a rate-limited answer
    when a previously unknown peer announces (so both sides learn about each other).
  * Scanning in the UI replays cached peers and sends at most one announce per
    USER_ANNOUNCE_MIN_GAP; peers come from received announces and a local cache file.
  * Paths are only requested when a transfer is actually started.
"""

import json
import os
import random
import shutil
import sys
import threading
import time
import traceback
from pathlib import Path

# Keep the real stdout exclusively for the JSON protocol.
_proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
sys.stdout = sys.stderr

output_lock = threading.Lock()


# Set by start_embedded() when the bridge runs inside another process (Android/Chaquopy)
# instead of as a child process speaking JSON lines over stdin/stdout.
_event_sink = None


def send_event(event_dict):
    line = json.dumps(event_dict, ensure_ascii=False)
    with output_lock:
        if _event_sink is not None:
            _event_sink(line)
            return
        _proto.write(line + "\n")
        _proto.flush()


try:
    import RNS
except ImportError as e:
    send_event({"event": "error", "message": f"RNS module not installed. Run: pip install rns  ({e})"})
    sys.exit(1)

RNS.logdest = RNS.LOG_CALLBACK
RNS.logcall = lambda msg: sys.stderr.write(msg + "\n")

APP_NAME = "localesnd-reticulum"
TRANSFER_ASPECT = "transfer"

ANNOUNCE_INTERVAL = 30 * 60        # periodic re-announce
ANNOUNCE_MIN_GAP = 5 * 60          # minimum gap between two automatic announces
USER_ANNOUNCE_MIN_GAP = 30         # minimum gap when the user scans or a new peer needs an answer
PEER_REFRESH_AFTER = 60 * 60       # an old peer re-announcing counts as "new" again
PEER_TTL = 7 * 24 * 3600           # forget cached peers after a week
PATH_WAIT = 25                     # seconds to wait for path/identity before a transfer fails
CONTROL_RESOURCE_MAX = 256 * 1024  # largest resource accepted before the user accepted a session
PROGRESS_MIN_INTERVAL = 0.25

RNS_CONFIG_DIR = None
STAGING_DIR = None
PEERS_FILE = None

identity = None
destination = None
reticulum = None
local_info = None
last_announce = 0.0
announce_lock = threading.Lock()
shutting_down = threading.Event()

active_sessions = {}
sessions_lock = threading.Lock()
peers = {}  # dest hex -> {"hash", "data", "last_seen"}


# --------------------------------------------------------------------------- peers

def _save_peers():
    if not PEERS_FILE:
        return
    try:
        serial = {h: {"hash": h, "data": p["data"], "last_seen": p["last_seen"]} for h, p in peers.items()}
        tmp = PEERS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(serial, f)
        os.replace(tmp, PEERS_FILE)
    except Exception as e:
        RNS.log(f"Could not save peers: {e}")


def _load_peers():
    if not PEERS_FILE or not os.path.exists(PEERS_FILE):
        return
    try:
        with open(PEERS_FILE) as f:
            data = json.load(f)
        now = time.time()
        for h, p in data.items():
            if now - p.get("last_seen", 0) < PEER_TTL:
                peers[h] = p
    except Exception as e:
        RNS.log(f"Could not load peers: {e}")


class AnnounceHandler:
    aspect_filter = f"{APP_NAME}.{TRANSFER_ASPECT}"

    def received_announce(self, destination_hash, announced_identity, app_data, *args, **kwargs):
        try:
            dest_hex = destination_hash.hex()
            RNS.log(f"Announce received from {dest_hex}", RNS.LOG_NOTICE)
            if destination is not None and destination_hash == destination.hash:
                return
            data = json.loads(app_data.decode("utf-8")) if app_data else {}
            if not isinstance(data, dict):
                data = {}
            now = time.time()
            old = peers.get(dest_hex)
            is_new = old is None or now - old["last_seen"] > PEER_REFRESH_AFTER
            peers[dest_hex] = {"hash": dest_hex, "data": data, "last_seen": now}
            _save_peers()
            send_event({"event": "peer_discovered", "destination_hash": dest_hex, "app_data": data})
            if is_new:
                _schedule_reply_announce()
        except Exception as e:
            send_event({"event": "error", "message": f"announce parse error: {e}"})


# --------------------------------------------------------------------------- announces

def _do_announce(force=False, min_gap=ANNOUNCE_MIN_GAP):
    global last_announce
    if destination is None or local_info is None:
        return False
    with announce_lock:
        now = time.time()
        if not force and now - last_announce < min_gap:
            return False
        last_announce = now
    destination.announce(app_data=json.dumps(local_info, ensure_ascii=False).encode("utf-8"))
    RNS.log(f"Announced {destination.hash.hex()}", RNS.LOG_NOTICE)
    send_event({"event": "announce_sent"})
    return True


def _schedule_reply_announce():
    # A new peer only learns about us from an announce, so answer it soon (still rate limited).
    if time.time() - last_announce < USER_ANNOUNCE_MIN_GAP:
        return
    t = threading.Timer(random.uniform(2, 10), lambda: _do_announce(min_gap=USER_ANNOUNCE_MIN_GAP))
    t.daemon = True
    t.start()


def _periodic_announce_loop():
    while not shutting_down.wait(ANNOUNCE_INTERVAL):
        try:
            _do_announce(force=True)
        except Exception as e:
            RNS.log(f"periodic announce failed: {e}")


# --------------------------------------------------------------------------- sessions

class Session:
    def __init__(self, session_id, link, role):
        self.session_id = session_id
        self.link = link
        self.role = role  # "sender" | "receiver"
        self.status = "new"  # new, pending, accepted, done, closed
        self.files = []
        self.paths = {}          # sender: file id -> (path, name)
        self.order = []          # accepted file ids, in transfer order
        self.started_count = 0   # receiver: number of data resources started
        self.finished = set()
        self.failed = set()
        self.cancelled = False
        self.completed = False
        self.lock = threading.Lock()

        link.set_link_closed_callback(self._on_closed)
        link.set_packet_callback(self._on_packet)
        link.set_resource_strategy(RNS.Link.ACCEPT_APP)
        link.set_resource_callback(self._resource_filter)
        link.set_resource_started_callback(self._on_resource_started)
        link.set_resource_concluded_callback(self._on_resource_concluded)

    def emit(self, event, **kw):
        send_event({"event": event, "session_id": self.session_id, "role": self.role, **kw})

    # ---- link lifecycle
    def _on_closed(self, link):
        was_open = self.status != "closed"
        self.status = "closed"
        with sessions_lock:
            active_sessions.pop(self.session_id, None)
        if was_open and not self.completed and not self.cancelled:
            reason = getattr(link, "teardown_reason", None)
            if self.role == "sender" and self.status_before_close in ("connecting",):
                self.emit("session_error", error="could not establish link to destination")
            elif self.finished or self.status_before_close in ("accepted",):
                self.emit("session_error", error="link lost before the transfer finished")
        self.emit("link_closed")

    status_before_close = "new"

    def teardown_later(self, delay=3.0):
        def _t():
            try:
                self.link.teardown()
            except Exception:
                pass
        timer = threading.Timer(delay, _t)
        timer.daemon = True
        timer.start()

    # ---- control channel
    def send_ctl(self, payload):
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if len(raw) <= RNS.Link.MDU:
            RNS.Packet(self.link, raw).send()
        else:
            RNS.Resource(raw, self.link, metadata={"ctl": 1}, auto_compress=True)

    def _resource_filter(self, resource):
        try:
            size = resource.get_data_size()
        except Exception:
            size = 0
        if self.role == "receiver" and self.status == "accepted":
            return True
        return size <= CONTROL_RESOURCE_MAX and not (self.role == "receiver" and self.status == "accepted")

    def _on_packet(self, message, packet):
        try:
            self._handle_ctl(json.loads(message.decode("utf-8")))
        except Exception as e:
            send_event({"event": "error", "message": f"control parse error: {e}"})

    def _handle_ctl(self, data):
        t = data.get("type")
        if t == "session_metadata" and self.role == "receiver" and self.status in ("new", "pending"):
            self.status = "pending"
            self.files = data.get("files", [])
            sender = data.get("sender", {}) or {}
            self.emit(
                "session_request",
                sender_hash=data.get("sender_hash", ""),
                files=self.files,
                sender_alias=sender.get("alias") or peers.get(data.get("sender_hash", ""), {}).get("data", {}).get("alias", "Unknown"),
                sender_version=sender.get("version", ""),
                sender_device_model=sender.get("device_model"),
            )
        elif t == "session_accept" and self.role == "sender":
            accepted = data.get("accepted_files", {}) or {}
            self.status = "accepted"
            self.status_before_close = "accepted"
            self.order = [fid for fid in accepted if fid in self.paths]
            self.emit("session_accepted", accepted_files=accepted)
            threading.Thread(target=self._send_all, daemon=True).start()
        elif t == "session_decline" and self.role == "sender":
            self.cancelled = True
            self.emit("session_declined")
            self.teardown_later(1.0)
        elif t == "session_cancel":
            self.cancelled = True
            self.emit("session_cancelled")
            self.teardown_later(1.0)

    # ---- receiver side
    def accept(self, accepted_files):
        self.order = list(accepted_files.keys())
        self.status = "accepted"
        self.status_before_close = "accepted"
        self.send_ctl({"type": "session_accept", "accepted_files": accepted_files})
        if not self.order:
            self._complete()

    def decline(self):
        self.cancelled = True
        try:
            self.send_ctl({"type": "session_decline"})
        finally:
            self.teardown_later(1.5)

    def cancel(self):
        self.cancelled = True
        try:
            self.send_ctl({"type": "session_cancel"})
        except Exception:
            pass
        self.teardown_later(0.5)

    def _on_resource_started(self, resource):
        if self.role != "receiver":
            return
        with self.lock:
            idx = self.started_count
            self.started_count += 1
        # Metadata is only readable once the resource is assembled, but the sender
        # transfers files sequentially in accepted order, so we can map by index.
        file_id = self.order[idx] if idx < len(self.order) else None
        if file_id is None:
            return

        def _poll():
            last = -1.0
            while resource.status in (RNS.Resource.ADVERTISED, RNS.Resource.TRANSFERRING, RNS.Resource.QUEUED):
                try:
                    p = float(resource.get_progress())
                except Exception:
                    break
                if p != last:
                    self.emit("transfer_progress", file_id=file_id, progress=p)
                    last = p
                time.sleep(0.5)

        threading.Thread(target=_poll, daemon=True).start()

    def _on_resource_concluded(self, resource):
        metadata = resource.metadata if isinstance(resource.metadata, dict) else {}
        if self.role == "sender" or metadata.get("ctl"):
            # control resource (large metadata / accept message)
            if resource.status == RNS.Resource.COMPLETE:
                try:
                    raw = resource.data.read() if hasattr(resource.data, "read") else resource.data
                    if hasattr(resource.data, "close"):
                        resource.data.close()
                    self._handle_ctl(json.loads(raw.decode("utf-8")))
                except Exception as e:
                    send_event({"event": "error", "message": f"control resource error: {e}"})
            return

        file_id = metadata.get("fileId")
        if file_id is None:
            with self.lock:
                pending = [f for f in self.order if f not in self.finished and f not in self.failed]
            file_id = pending[0] if pending else "unknown"

        if resource.status == RNS.Resource.COMPLETE:
            try:
                dest = Path(STAGING_DIR) / f"{self.session_id}_{file_id}"
                data = resource.data
                if hasattr(data, "name") and hasattr(data, "read") and os.path.exists(data.name):
                    src = data.name
                    data.close()
                    shutil.move(src, dest)
                else:
                    with open(dest, "wb") as f:
                        f.write(data if isinstance(data, (bytes, bytearray)) else bytes(data))
                self.finished.add(file_id)
                self.emit("transfer_progress", file_id=file_id, progress=1.0)
                self.emit("transfer_complete", file_id=file_id, path=str(dest))
            except Exception as e:
                self.failed.add(file_id)
                self.emit("transfer_failed", file_id=file_id, error=str(e))
        else:
            self.failed.add(file_id)
            self.emit("transfer_failed", file_id=file_id, error=f"resource failed (status {resource.status})")

        if len(self.finished) + len(self.failed) >= len(self.order):
            self._complete()

    def _complete(self):
        if self.completed:
            return
        self.completed = True
        self.status = "done"
        self.emit("session_complete", failed=sorted(self.failed))
        self.teardown_later(3.0)

    # ---- sender side
    def _send_all(self):
        for file_id in self.order:
            if self.cancelled or self.status == "closed":
                return
            path, name = self.paths[file_id]
            done = threading.Event()
            result = {}
            fh = None
            try:
                fh = open(path, "rb")
                last = [0.0]

                def on_progress(r, fid=file_id, last=last):
                    now = time.time()
                    if now - last[0] >= PROGRESS_MIN_INTERVAL:
                        last[0] = now
                        self.emit("transfer_progress", file_id=fid, progress=float(r.get_progress()))

                def on_done(r, res=result, ev=done):
                    res["status"] = r.status
                    ev.set()

                RNS.Resource(
                    fh, self.link,
                    metadata={"fileId": file_id, "fileName": name},
                    callback=on_done, progress_callback=on_progress,
                )
                while not done.wait(1.0):
                    if self.cancelled or self.status == "closed":
                        return
            except Exception as e:
                self.failed.add(file_id)
                self.emit("transfer_failed", file_id=file_id, error=str(e))
                continue
            finally:
                if fh:
                    try:
                        fh.close()
                    except Exception:
                        pass
            if result.get("status") == RNS.Resource.COMPLETE:
                self.finished.add(file_id)
                self.emit("transfer_progress", file_id=file_id, progress=1.0)
                self.emit("transfer_complete", file_id=file_id, path=None)
            else:
                self.failed.add(file_id)
                self.emit("transfer_failed", file_id=file_id, error="transfer did not complete")
        self._complete()


def on_link_established(link):
    session_id = f"rx_{link.hash.hex()[:12]}"
    session = Session(session_id, link, "receiver")
    with sessions_lock:
        active_sessions[session_id] = session
    RNS.log(f"Incoming link, session={session_id}")


# --------------------------------------------------------------------------- init

MINIMAL_CONFIG = """[reticulum]
  enable_transport = False

[logging]
  loglevel = 3

[interfaces]
  [[Default Interface]]
    type = AutoInterface
    enabled = yes
"""


def _expand(p):
    return os.path.expanduser(p) if p else p


def cmd_init(config_path, identity_path, staging_dir=None, **_):
    global RNS_CONFIG_DIR, STAGING_DIR, PEERS_FILE, identity, destination, reticulum

    RNS_CONFIG_DIR = _expand(config_path)
    identity_path = _expand(identity_path)
    STAGING_DIR = _expand(staging_dir) or os.path.join(os.path.dirname(identity_path), ".localsend_rns_staging")
    PEERS_FILE = identity_path + ".peers.json"
    os.makedirs(STAGING_DIR, exist_ok=True)

    # Never touch an existing user config; only create one if there is none.
    cfg = Path(RNS_CONFIG_DIR) / "config"
    if not cfg.exists():
        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text(MINIMAL_CONFIG)

    try:
        reticulum = RNS.Reticulum(RNS_CONFIG_DIR)
    except Exception as e:
        send_event({"event": "bridge_error", "message": f"Reticulum failed to start: {e}"})
        return

    if os.path.exists(identity_path):
        identity = RNS.Identity.from_file(identity_path)
    if identity is None:
        identity = RNS.Identity()
        identity.to_file(identity_path)

    destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, APP_NAME, TRANSFER_ASPECT)
    destination.set_link_established_callback(on_link_established)
    RNS.Transport.register_announce_handler(AnnounceHandler())

    for iface in RNS.Transport.interfaces:
        RNS.log(f"Interface: {iface} online={getattr(iface, 'online', '?')}", RNS.LOG_NOTICE)
    RNS.log(f"Destination: {destination.hash.hex()}", RNS.LOG_NOTICE)

    _load_peers()
    threading.Thread(target=_periodic_announce_loop, daemon=True).start()

    send_event({
        "event": "ready",
        "identity_hash": identity.hash.hex(),
        "destination_hash": destination.hash.hex(),
        "identity_pub": identity.get_public_key().hex(),
    })
    _emit_peer_list()


def _emit_peer_list():
    send_event({"event": "peer_list", "peers": [{"hash": p["hash"], "data": p["data"], "last_seen": p["last_seen"]} for p in peers.values()]})
    for p in list(peers.values()):
        send_event({"event": "peer_discovered", "destination_hash": p["hash"], "app_data": p["data"]})


def cmd_announce(app_data, **_):
    """Stores our announce data. Announces right away only if the rate limit allows it."""
    global local_info
    if destination is None:
        send_event({"event": "error", "message": "not initialized"})
        return
    first = local_info is None
    changed = local_info != app_data
    local_info = app_data
    _do_announce(force=first or (changed and time.time() - last_announce > 30))


def cmd_get_peers(**_):
    _emit_peer_list()


def cmd_refresh(**_):
    """User-initiated scan: replay cached peers and announce (rate limited) so others find us."""
    _emit_peer_list()
    _do_announce(min_gap=USER_ANNOUNCE_MIN_GAP)


def cmd_request_path(dest_hex, **_):
    try:
        RNS.Transport.request_path(bytes.fromhex(dest_hex))
        send_event({"event": "path_requested", "destination_hash": dest_hex})
    except ValueError:
        send_event({"event": "error", "message": f"invalid hash: {dest_hex}"})


# --------------------------------------------------------------------------- sending

def _fail(session_id, msg):
    send_event({"event": "session_error", "session_id": session_id, "role": "sender", "error": msg})


def _connect_and_send(session_id, dest_hex, files):
    try:
        dest_hash = bytes.fromhex(dest_hex.strip())
        if len(dest_hash) != RNS.Reticulum.TRUNCATED_HASHLENGTH // 8:
            raise ValueError("wrong length")
    except ValueError:
        return _fail(session_id, f"invalid destination hash: {dest_hex}")

    send_event({"event": "session_connecting", "session_id": session_id, "role": "sender"})

    if not RNS.Transport.has_path(dest_hash):
        RNS.Transport.request_path(dest_hash)
    deadline = time.time() + PATH_WAIT
    server_identity = None
    while time.time() < deadline:
        if RNS.Transport.has_path(dest_hash):
            server_identity = RNS.Identity.recall(dest_hash)
            if server_identity is not None:
                break
        time.sleep(0.2)
    if server_identity is None:
        return _fail(session_id, "destination unreachable (no path/identity)")

    out_dest = RNS.Destination(server_identity, RNS.Destination.OUT, RNS.Destination.SINGLE, APP_NAME, TRANSFER_ASPECT)
    link = RNS.Link(out_dest)
    session = Session(session_id, link, "sender")
    session.status_before_close = "connecting"
    session.paths = {f["id"]: (f["path"], f.get("file_name", f["id"])) for f in files if f.get("path")}
    with sessions_lock:
        active_sessions[session_id] = session

    wire_files = [{k: v for k, v in f.items() if k != "path"} for f in files]

    def on_established(l):
        session.status = "pending"
        session.status_before_close = "pending"
        try:
            session.send_ctl({
                "type": "session_metadata",
                "files": wire_files,
                "sender_hash": destination.hash.hex(),
                "sender": local_info or {},
            })
            session.emit("session_established")
        except Exception as e:
            session.emit("session_error", error=f"failed to send metadata: {e}")

    link.set_link_established_callback(on_established)


def cmd_send_session(dest_hex, files, session_id=None, **_):
    if identity is None:
        send_event({"event": "error", "message": "not initialized"})
        return
    session_id = session_id or f"tx_{dest_hex[:8]}_{int(time.time() * 1000)}"
    threading.Thread(target=_connect_and_send, args=(session_id, dest_hex, files), daemon=True).start()


def _get_session(session_id):
    with sessions_lock:
        s = active_sessions.get(session_id)
    if not s:
        send_event({"event": "error", "message": f"session {session_id} not found"})
    return s


def cmd_accept_session(session_id, accepted_files, **_):
    s = _get_session(session_id)
    if s:
        s.accept(accepted_files)


def cmd_decline_session(session_id, **_):
    s = _get_session(session_id)
    if s:
        s.decline()


def cmd_cancel_session(session_id, **_):
    with sessions_lock:
        s = active_sessions.get(session_id)
    if s:
        s.cancel()
    else:
        # sender may cancel while still resolving the path: nothing to tear down
        send_event({"event": "session_cancelled", "session_id": session_id, "role": "sender"})


# --------------------------------------------------------------------------- interfaces config

def _load_config():
    from RNS.vendor.configobj import ConfigObj
    return ConfigObj(str(Path(RNS_CONFIG_DIR) / "config"))


def _yes(v):
    return str(v).strip().lower() in ("yes", "true", "1", "on")


def cmd_get_interfaces(**_):
    if not RNS_CONFIG_DIR:
        return send_event({"event": "error", "message": "not initialized"})
    try:
        conf = _load_config()
        out = []
        for name, sec in (conf.get("interfaces") or {}).items():
            if not hasattr(sec, "items"):
                continue
            entry = {k: v for k, v in sec.items() if isinstance(v, (str, list))}
            if "peers" in entry and isinstance(entry["peers"], str):
                entry["peers"] = [entry["peers"]]
            entry["name"] = name
            entry["type"] = sec.get("type", "")
            entry["enabled"] = _yes(sec.get("enabled", sec.get("interface_enabled", "yes")))
            out.append(entry)
        send_event({"event": "interfaces_list", "interfaces": out})
    except Exception as e:
        send_event({"event": "error", "message": f"failed to read interfaces: {e}"})


def cmd_configure_interfaces(interfaces, **_):
    """Updates interfaces in place, preserving every key/comment the app does not manage."""
    if not RNS_CONFIG_DIR:
        return send_event({"event": "error", "message": "not initialized"})
    try:
        cfg = Path(RNS_CONFIG_DIR) / "config"
        shutil.copyfile(cfg, str(cfg) + ".bak")
        conf = _load_config()
        if "interfaces" not in conf:
            conf["interfaces"] = {}
        section = conf["interfaces"]
        wanted = set()
        for iface in interfaces:
            name = iface.get("name", "Unnamed Interface")
            wanted.add(name)
            if name not in section:
                section[name] = {}
            sec = section[name]
            sec["type"] = iface.get("type", "TCPClientInterface")
            sec["enabled"] = "yes" if iface.get("enabled", True) else "no"
            for key in ("target_host", "target_port", "listen_port"):
                if iface.get(key):
                    sec[key] = str(iface[key])
            if iface.get("peers"):
                sec["peers"] = iface["peers"]
        for name in list(section.keys()):
            if name not in wanted:
                del section[name]
        conf.write()
        send_event({"event": "interfaces_configured", "count": len(interfaces),
                    "message": "Restart the app for interface changes to take effect"})
    except Exception as e:
        send_event({"event": "error", "message": f"failed to configure interfaces: {e}"})


COMMANDS = {
    "init": cmd_init,
    "announce": cmd_announce,
    "send_session": cmd_send_session,
    "accept_session": cmd_accept_session,
    "decline_session": cmd_decline_session,
    "cancel_session": cmd_cancel_session,
    "request_path": cmd_request_path,
    "get_peers": cmd_get_peers,
    "refresh": cmd_refresh,
    "configure_interfaces": cmd_configure_interfaces,
    "get_interfaces": cmd_get_interfaces,
}


def handle_line(line):
    """Handle one JSON command line. Returns False when the bridge should shut down."""
    line = line.strip()
    if not line:
        return True
    try:
        msg = json.loads(line)
        cmd = msg.pop("cmd", None)
        msg.pop("request_id", None)
        if cmd == "shutdown":
            send_event({"event": "shutdown"})
            return False
        handler = COMMANDS.get(cmd)
        if handler:
            handler(**msg)
        else:
            send_event({"event": "error", "message": f"unknown command: {cmd}"})
    except json.JSONDecodeError as e:
        send_event({"event": "error", "message": f"invalid JSON: {e}"})
    except Exception as e:
        send_event({"event": "error", "message": f"unhandled: {e}\n{traceback.format_exc()}"})
    return True


def main_loop():
    for line in sys.stdin:
        if not handle_line(line):
            break
    shutting_down.set()
    os._exit(0)


def start_embedded(sink):
    """Embedded mode: events are delivered to sink(json_line); commands go through handle_line()."""
    global _event_sink
    _event_sink = sink


def stop_embedded():
    shutting_down.set()


if __name__ == "__main__":
    main_loop()
