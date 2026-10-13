import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:common/constants.dart';
import 'package:common/isolate.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/file_status.dart';
import 'package:common/model/file_type.dart';
import 'package:common/model/session_status.dart';
import 'package:common/src/rns/rns_bridge.dart';
import 'package:common/src/rns/rns_discovery_service.dart';
import 'package:common/src/rns/rns_file_transfer.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/controller/send_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/native/file_saver.dart';
import 'package:localsend_app/util/simple_server.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('Server');

/// This provider runs the server and provides the current server state.
/// It is a singleton provider, so only one server can be running at a time.
/// The server state is null if the server is not running.
/// The server can receive files (since v1) and send files (since v2).
final serverProvider = NotifierProvider<ServerService, ServerState?>(
  (ref) {
    return ServerService();
  },
  onChanged: (_, next, ref) {
    final settings = ref.read(settingsProvider);
    final syncState = ref.read(parentIsolateProvider).syncState;
    final syncStatePrev = (syncState.alias, syncState.port, syncState.protocol, syncState.serverRunning, syncState.download);
    final syncStateNext = (
      next?.alias ?? settings.alias,
      next?.port ?? settings.port,
      (next?.https ?? settings.https) ? ProtocolType.https : ProtocolType.http,
      next != null,
      next?.webSendState != null,
    );

    if (syncStatePrev == syncStateNext) {
      return;
    }

    ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateSyncServerStateAction(
            alias: syncStateNext.$1,
            port: syncStateNext.$2,
            protocol: syncStateNext.$3,
            serverRunning: syncStateNext.$4,
            download: syncStateNext.$5,
          ),
        );
  },
);

class ServerService extends Notifier<ServerState?> {
  late final _serverUtils = ServerUtils(
    refFunc: () => ref,
    getState: () => state!,
    getStateOrNull: () => state,
    setState: (builder) => state = builder(state),
  );

  late final _receiveController = ReceiveController(_serverUtils);
  late final _sendController = SendController(_serverUtils);

  RnsAnnounceService? _rnsAnnounce;
  RnsFileTransferService? _rnsTransfer;
  RnsBridge? _rnsBridge;
  StreamSubscription<RnsBridgeEvent>? _rnsSubscription;
  String? _rnsSessionId;

  static const _uuid = Uuid();

  ServerService();

  void attachRns(RnsAnnounceService announce, RnsFileTransferService transfer, RnsBridge bridge) {
    _rnsAnnounce = announce;
    _rnsTransfer = transfer;
    _rnsBridge = bridge;
    _rnsSubscription?.cancel();
    _rnsSubscription = bridge.events.listen(_handleRnsEvent);
  }

  void detachRns() {
    _rnsSubscription?.cancel();
    _rnsSubscription = null;
    _rnsAnnounce = null;
    _rnsTransfer = null;
    _rnsBridge = null;
    _rnsSessionId = null;
  }

  void _handleRnsEvent(RnsBridgeEvent event) {
    if (event.data['role'] != 'receiver') {
      return;
    }
    // Events of an old/foreign session must not touch the current one.
    final eventSession = event.data['session_id'] as String?;
    if (event.type != 'session_request' && eventSession != _rnsSessionId) {
      return;
    }

    switch (event.type) {
      case 'session_request':
        unawaited(_handleRnsSessionRequest(event));
        break;
      case 'transfer_progress':
        final fileId = event.data['file_id'] as String?;
        final session = state?.session;
        if (fileId != null && session != null) {
          ref
              .notifier(progressProvider)
              .setProgress(
                sessionId: session.sessionId,
                fileId: fileId,
                progress: (event.data['progress'] as num?)?.toDouble() ?? 0,
              );
        }
        break;
      case 'transfer_complete':
        unawaited(_handleRnsTransferComplete(event));
        break;
      case 'transfer_failed':
        _setRnsFileResult(event.data['file_id'] as String?, FileStatus.failed, event.data['error'] as String?);
        break;
      case 'session_complete':
        _finishRnsSession();
        break;
      case 'session_cancelled':
        _endRnsSession(SessionStatus.canceledBySender);
        break;
      case 'session_error':
      case 'link_closed':
        // link_closed after a finished session is expected and ignored
        final status = state?.session?.status;
        if (status == SessionStatus.waiting || status == SessionStatus.sending) {
          _endRnsSession(SessionStatus.finishedWithErrors);
        }
        break;
    }
  }

  Future<void> _handleRnsSessionRequest(RnsBridgeEvent event) async {
    final rnsSessionId = event.data['session_id'] as String;
    final files = (event.data['files'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    if (files.isEmpty || state == null || state?.session != null) {
      _logger.warning('Declining RNS request (empty, server not running or already in a session)');
      _rnsTransfer?.declineSession(rnsSessionId);
      return;
    }

    final senderHash = event.data['sender_hash'] as String? ?? '';
    final alias = event.data['sender_alias'] as String? ?? 'Unknown';
    final sessionId = _uuid.v4();
    _rnsSessionId = rnsSessionId;
    _rnsBridgeDone = false;

    final sender = Device(
      signalingId: null,
      ip: null,
      destinationHash: senderHash,
      version: event.data['sender_version'] as String? ?? '',
      port: 0,
      https: false,
      fingerprint: senderHash,
      alias: alias,
      deviceModel: event.data['sender_device_model'] as String?,
      deviceType: DeviceType.desktop,
      download: false,
      discoveryMethods: {},
    );

    final fileEntries = <String, ReceivingFile>{};
    for (final f in files) {
      final id = f['id'] as String? ?? _uuid.v4();
      final typeStr = f['type'] as String? ?? 'other';
      fileEntries[id] = ReceivingFile(
        file: FileDto(
          id: id,
          fileName: f['file_name'] as String? ?? 'unknown',
          size: (f['size'] as num?)?.toInt() ?? 0,
          fileType: FileType.values.firstWhere((ft) => ft.name == typeStr, orElse: () => FileType.other),
          hash: null,
          preview: null,
          metadata: null,
        ),
        status: FileStatus.queue,
        token: null,
        desiredName: null,
        path: null,
        savedToGallery: false,
        errorMessage: null,
      );
    }

    final settings = ref.read(settingsProvider);
    final destinationDir = settings.destination ?? await getDefaultDestinationDirectory();
    final cacheDir = await getCacheDirectory();

    state = state?.copyWith(
      session: ReceiveSessionState(
        sessionId: sessionId,
        status: SessionStatus.waiting,
        sender: sender,
        senderAlias: alias,
        files: fileEntries,
        startTime: null,
        endTime: null,
        destinationDirectory: destinationDir,
        cacheDirectory: cacheDir,
        saveToGallery: false,
        createdDirectories: {},
        responseHandler: null,
      ),
    );

    if (settings.quickSave) {
      acceptRnsSession({for (final e in fileEntries.entries) e.key: e.value.file.fileName});
      unawaited(
        Routerino.context.push(() => ProgressPage(showAppBar: false, closeSessionOnClose: true, sessionId: sessionId)),
      );
      return;
    }

    final receiveProvider = ViewProvider((ref) {
      final session = ref.watch(serverProvider.select((s) => s?.session));
      return ReceivePageVm(
        status: session?.status,
        sender: session?.sender ?? Device.empty,
        showSenderInfo: true,
        files: session?.files.values.map((f) => f.file).toList() ?? [],
        message: null,
        onAccept: () async {
          final sid = ref.read(serverProvider)?.session?.sessionId;
          if (sid == null) return;
          acceptRnsSession(ref.read(selectedReceivingFilesProvider));

          await Routerino.context.pushAndRemoveUntilImmediately(
            removeUntil: ReceivePage,
            builder: () => ProgressPage(showAppBar: false, closeSessionOnClose: true, sessionId: sid),
          );
        },
        onDecline: declineRnsSession,
        onClose: closeRnsSession,
      );
    });

    // ignore: unawaited_futures
    Routerino.context.push(() => ReceivePage(receiveProvider));
  }

  /// [selection] maps file id -> desired file name, same as for HTTP.
  void acceptRnsSession(Map<String, String> selection) {
    final rnsSessionId = _rnsSessionId;
    final session = state?.session;
    if (rnsSessionId == null || session == null) return;

    _rnsTransfer?.acceptSession(rnsSessionId, selection);

    state = state?.copyWith(
      session: session.copyWith(
        status: selection.isEmpty ? SessionStatus.finished : SessionStatus.sending,
        startTime: DateTime.now().millisecondsSinceEpoch,
        files: {
          for (final e in session.files.entries)
            e.key: e.value.copyWith(
              status: selection.containsKey(e.key) ? FileStatus.sending : FileStatus.skipped,
              desiredName: selection[e.key],
            ),
        },
      ),
    );
  }

  void declineRnsSession() {
    final rnsSessionId = _rnsSessionId;
    if (rnsSessionId == null) return;

    _rnsTransfer?.declineSession(rnsSessionId);
    closeRnsSession();
  }

  void closeRnsSession() {
    final sessionId = state?.session?.sessionId;
    if (sessionId != null) {
      ref.notifier(progressProvider).removeSession(sessionId);
    }
    _rnsSessionId = null;
    state = state?.copyWith(session: null);
  }

  void _setRnsFileResult(String? fileId, FileStatus status, String? error, {String? path}) {
    final session = state?.session;
    final file = fileId == null ? null : session?.files[fileId];
    if (session == null || file == null) return;
    state = state?.copyWith(
      session: session.copyWith(
        files: {...session.files, fileId!: file.copyWith(status: status, errorMessage: error, path: path ?? file.path)},
      ),
    );
  }

  Future<void> _handleRnsTransferComplete(RnsBridgeEvent event) async {
    final fileId = event.data['file_id'] as String?;
    final stagedPath = event.data['path'] as String?;
    final session = state?.session;
    final file = fileId == null ? null : session?.files[fileId];
    if (session == null || file == null || stagedPath == null) return;

    final staged = File(stagedPath);
    try {
      final (savedToGallery, savedPath) = await saveFile(
        destinationDirectory: session.destinationDirectory,
        fileName: file.desiredName ?? file.file.fileName,
        saveToGallery: false,
        isImage: file.file.fileType == FileType.image,
        stream: staged.openRead().map(Uint8List.fromList),
        onProgress: (_) {},
        androidSdkInt: ref.read(deviceInfoProvider).androidSdkInt,
        createdDirectories: session.createdDirectories,
      );
      _setRnsFileResult(fileId, FileStatus.finished, null, path: savedPath);
      ref.notifier(progressProvider).setProgress(sessionId: session.sessionId, fileId: fileId!, progress: 1);

      await ref
          .redux(receiveHistoryProvider)
          .dispatchAsync(
            AddHistoryEntryAction(
              entryId: fileId,
              fileName: file.desiredName ?? file.file.fileName,
              fileType: file.file.fileType,
              path: savedPath,
              savedToGallery: savedToGallery,
              isMessage: false,
              fileSize: file.file.size,
              senderAlias: session.senderAlias,
              timestamp: DateTime.now().toUtc(),
            ),
          );
    } catch (e, st) {
      _logger.warning('Failed to save received RNS file', e, st);
      _setRnsFileResult(fileId, FileStatus.failed, e.toString());
    } finally {
      try {
        await staged.delete();
      } catch (_) {}
    }
    _maybeFinishRnsSession();
  }

  bool _rnsBridgeDone = false;

  /// The bridge says all transfers are over; the session ends once all files are saved.
  void _finishRnsSession() {
    _rnsBridgeDone = true;
    _maybeFinishRnsSession();
  }

  void _maybeFinishRnsSession() {
    final session = state?.session;
    if (!_rnsBridgeDone || session == null || session.status != SessionStatus.sending) return;
    if (session.files.values.any((f) => f.status == FileStatus.sending || f.status == FileStatus.queue)) return;
    _endRnsSession(
      session.files.values.any((f) => f.status == FileStatus.failed) ? SessionStatus.finishedWithErrors : SessionStatus.finished,
    );
  }

  void _endRnsSession(SessionStatus status) {
    final session = state?.session;
    if (session == null) return;
    _rnsBridgeDone = false;
    state = state?.copyWith(
      session: session.copyWith(status: status, endTime: DateTime.now().millisecondsSinceEpoch),
    );
  }

  @override
  ServerState? init() {
    return null;
  }

  /// Starts the server from user settings.
  Future<ServerState?> startServerFromSettings() async {
    final settings = ref.read(settingsProvider);
    return startServer(
      alias: settings.alias,
      port: settings.port,
      https: settings.https,
    );
  }

  /// Starts the server.
  Future<ServerState?> startServer({
    required String alias,
    required int port,
    required bool https,
  }) async {
    if (state != null) {
      _logger.info('Server already running.');
      return null;
    }

    alias = alias.trim();
    if (alias.isEmpty) {
      alias = generateRandomAlias();
    }

    if (port < 0 || port > 65535) {
      port = defaultPort;
    }

    final router = SimpleServerRouteBuilder();
    final fingerprint = ref.read(securityProvider).certificateHash;
    _receiveController.installRoutes(
      router: router,
      alias: alias,
      port: port,
      https: https,
      fingerprint: fingerprint,
      showToken: ref.read(settingsProvider).showToken,
    );
    _sendController.installRoutes(
      router: router,
      alias: alias,
      fingerprint: fingerprint,
    );

    _logger.info('Starting server...');

    final HttpServer httpServer;
    if (https) {
      final securityContext = ref.read(securityProvider);
      httpServer = await HttpServer.bindSecure(
        '0.0.0.0',
        port,
        SecurityContext()
          ..usePrivateKeyBytes(securityContext.privateKey.codeUnits)
          ..useCertificateChainBytes(securityContext.certificate.codeUnits),
      );
      _logger.info('Server started. (Port: $port, HTTPS only)');
    } else {
      httpServer = await HttpServer.bind(
        '0.0.0.0',
        port,
      );
      _logger.info('Server started. (Port: $port, HTTP only)');
    }

    final server = SimpleServer.start(server: httpServer, routes: router);

    final newServerState = ServerState(
      httpServer: server,
      alias: alias,
      port: port,
      https: https,
      session: null,
      webSendState: null,
      pinAttempts: {},
    );

    state = newServerState;
    return newServerState;
  }

  Future<void> stopServer() async {
    _logger.info('Stopping server...');
    await state?.httpServer.close();
    state = null;
    _logger.info('Server stopped.');
  }

  Future<ServerState?> restartServerFromSettings() async {
    await stopServer();
    return await startServerFromSettings();
  }

  Future<ServerState?> restartServer({required String alias, required int port, required bool https}) async {
    await stopServer();
    return await startServer(alias: alias, port: port, https: https);
  }

  void acceptFileRequest(Map<String, String> fileNameMap) {
    _receiveController.acceptFileRequest(fileNameMap);
  }

  void declineFileRequest() {
    _receiveController.declineFileRequest();
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory) {
    _receiveController.setSessionDestinationDir(destinationDirectory);
  }

  /// Updates the save to gallery setting for the current session.
  void setSessionSaveToGallery(bool saveToGallery) {
    _receiveController.setSessionSaveToGallery(saveToGallery);
  }

  /// In addition to [closeSession], this method also cancels incoming requests.
  void cancelSession() {
    if (_rnsSessionId != null) {
      _rnsTransfer?.cancelSession(_rnsSessionId!);
      closeRnsSession();
      return;
    }
    _receiveController.cancelSession();
  }

  /// Clears the session.
  void closeSession() {
    if (_rnsSessionId != null) {
      closeRnsSession();
      return;
    }
    _receiveController.closeSession();
  }

  /// Initializes the web send state.
  Future<void> initializeWebSend(List<CrossFile> files) async {
    await _sendController.initializeWebSend(files: files);
  }

  /// Updates the web send pin.
  void setWebSendPin(String? pin) {
    state = state?.copyWith(
      webSendState: state?.webSendState?.copyWith(
        pin: pin,
      ),
    );
  }

  /// Updates the auto accept setting for web send.
  void setWebSendAutoAccept(bool autoAccept) {
    state = state?.copyWith(
      webSendState: state?.webSendState?.copyWith(
        autoAccept: autoAccept,
      ),
    );
  }

  /// Accepts the web send request.
  void acceptWebSendRequest(String sessionId) {
    _sendController.acceptRequest(sessionId);
  }

  /// Declines the web send request.
  void declineWebSendRequest(String sessionId) {
    _sendController.declineRequest(sessionId);
  }
}

// Below is a first prototype of mTLS (mutual TLS).
// Problem:
// - we cannot request client certificates while ignoring errors

// Future<HttpServer> _startServer({
//   required Router router,
//   required int port,
//   required SecurityContext? securityContext,
// }) async {
//   const address = '0.0.0.0';
//   final server = await (securityContext == null
//       ? HttpServer.bind(address, port)
//       : HttpServer.bindSecure(
//     address,
//     port,
//     securityContext,
//     requestClientCertificate: true,
//   ));
//
//   final stream = server.map((request) {
//     print('Request Cert: ${request.certificate?.pem}');
//     return request;
//   });
//
//   serveRequests(stream, router);
//   return server;
// }
