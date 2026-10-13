import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('RnsBridge');

class RnsBridgeEvent {
  final String type;
  final Map<String, dynamic> data;

  RnsBridgeEvent(this.type, this.data);
}

class RnsBridge {
  Process? _process;
  final StreamController<RnsBridgeEvent> _eventController = StreamController<RnsBridgeEvent>.broadcast();
  bool _running = false;
  void Function(String line)? _write;
  String? _lastError;
  int _requestId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  Stream<RnsBridgeEvent> get events => _eventController.stream;
  bool get isRunning => _running;

  /// Last startup/runtime failure, so a page opened after the failure can still show it.
  String? get lastError => _lastError;

  void _fail(String message) {
    _lastError = message;
    _eventController.add(RnsBridgeEvent('bridge_error', {'message': message}));
  }

  void reportError(String message) => _fail(message);

  /// Runs the bridge over an externally provided transport (e.g. an in-process Python on Android)
  /// instead of spawning a child process. [incoming] yields JSON lines, [write] sends one.
  Future<void> startExternal({
    required Stream<String> incoming,
    required void Function(String line) write,
    required String configPath,
    required String identityPath,
    required String stagingDir,
  }) async {
    if (_running) {
      _logger.warning('Bridge already running');
      return;
    }
    _lastError = null;
    _write = write;
    _running = true;
    incoming.listen(
      _handleLine,
      onError: (Object e) => _fail('Bridge transport error: $e'),
    );
    await sendCommand('init', {
      'config_path': configPath,
      'identity_path': identityPath,
      'staging_dir': stagingDir,
    });
  }

  Future<void> start({
    required String pythonPath,
    required String bridgeScriptPath,
    required String configPath,
    required String identityPath,
    required String stagingDir,
  }) async {
    if (_running) {
      _logger.warning('Bridge already running');
      return;
    }

    // Verify the script exists
    final scriptFile = File(bridgeScriptPath);
    if (!await scriptFile.exists()) {
      _logger.severe('Bridge script not found at: $bridgeScriptPath');
      _fail('Script not found: $bridgeScriptPath');
      return;
    }

    // Ensure staging dir exists
    try {
      await Directory(stagingDir).create(recursive: true);
    } catch (_) {}

    try {
      _process = await Process.start(
        pythonPath,
        [scriptFile.absolute.path],
        environment: {},
        runInShell: true,
      );
    } catch (e) {
      _logger.severe('Failed to start Python process: $e');
      _fail('Failed to start Python: $e');
      return;
    }

    _running = true;
    _write = _process!.stdin.writeln;

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _logger.warning('Bridge stderr: $line');
    });

    _process!.exitCode.then((code) {
      _logger.info('Bridge exited with code $code');
      _running = false;
      _lastError ??= 'Bridge exited with code $code';
      _eventController.add(RnsBridgeEvent('bridge_exited', {'code': code}));
    });

    // Give the bridge a moment to start up, then init
    await Future.delayed(const Duration(milliseconds: 200));
    await sendCommand('init', {
      'config_path': configPath,
      'identity_path': identityPath,
      'staging_dir': stagingDir,
    });
  }

  void _handleLine(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      final event = msg['event'] as String?;
      if (event == 'bridge_error') {
        _lastError = msg['message'] as String?;
      } else if (event == 'ready') {
        _lastError = null;
      }
      if (event != null) {
        _eventController.add(RnsBridgeEvent(event, msg));
      }

      final requestId = msg['request_id'] as String?;
      if (requestId != null && _pendingRequests.containsKey(requestId)) {
        _pendingRequests[requestId]!.complete(msg);
        _pendingRequests.remove(requestId);
      }
    } catch (e) {
      _logger.warning('Failed to parse bridge message: $e');
    }
  }

  Future<void> sendCommand(String cmd, Map<String, dynamic> params) async {
    final write = _write;
    if (!_running || write == null) {
      _logger.warning('Bridge not running, skipping command: $cmd');
      return;
    }

    final msg = jsonEncode({'cmd': cmd, ...params});
    write(msg);
  }

  Future<Map<String, dynamic>> sendCommandWithResponse(String cmd, Map<String, dynamic> params) async {
    final requestId = 'req_${_requestId++}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;

    await sendCommand(cmd, {...params, 'request_id': requestId});

    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> announce(Map<String, dynamic> appData) async {
    await sendCommand('announce', {'app_data': appData});
    _logger.info('Announce sent');
  }

  /// [files] entries carry id, file_name, size, type and the local `path` (the path never leaves the device).
  Future<void> sendSession(String sessionId, String destHash, List<Map<String, dynamic>> files) async {
    await sendCommand('send_session', {'session_id': sessionId, 'dest_hex': destHash, 'files': files});
  }

  Future<void> acceptSession(String sessionId, Map<String, String> acceptedFiles) async {
    await sendCommand('accept_session', {'session_id': sessionId, 'accepted_files': acceptedFiles});
  }

  Future<void> declineSession(String sessionId) async {
    await sendCommand('decline_session', {'session_id': sessionId});
  }

  Future<void> cancelSession(String sessionId) async {
    await sendCommand('cancel_session', {'session_id': sessionId});
  }

  Future<void> sendFile(String sessionId, String filePath, String fileId, String fileName) async {
    await sendCommand('send_file', {
      'session_id': sessionId,
      'file_path': filePath,
      'file_id': fileId,
      'file_name': fileName,
    });
  }

  Future<void> configureInterfaces(List<Map<String, dynamic>> interfaces) async {
    await sendCommand('configure_interfaces', {'interfaces': interfaces});
  }

  Future<void> getInterfaces() async {
    await sendCommand('get_interfaces', {});
  }

  Future<void> getPeers() async {
    await sendCommand('get_peers', {});
  }

  /// User-initiated scan: replays cached peers and announces (rate limited by the bridge).
  Future<void> refresh() async {
    await sendCommand('refresh', {});
  }

  Future<void> shutdown() async {
    if (!_running) return;
    try {
      await sendCommand('shutdown', {});
      await _process?.stdin.close();
    } catch (_) {}
    _process?.kill();
    _running = false;
    await _eventController.close();
  }

  void dispose() {
    shutdown();
  }
}

RnsBridgeEvent? _parseBridgeEvent(Map<String, dynamic> msg) {
  final event = msg['event'] as String?;
  if (event == null) return null;
  return RnsBridgeEvent(event, msg);
}
