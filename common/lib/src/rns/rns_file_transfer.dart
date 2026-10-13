import 'dart:async';

import 'package:common/src/rns/rns_bridge.dart';
import 'package:logging/logging.dart';

final _logger = Logger('RnsFileTransfer');

class RnsTransferProgress {
  final String sessionId;
  final String fileId;
  final double progress;

  RnsTransferProgress({
    required this.sessionId,
    required this.fileId,
    required this.progress,
  });
}

class RnsTransferSession {
  final String sessionId;
  final bool isSender;
  final String? remoteHash;

  RnsTransferSession({
    required this.sessionId,
    required this.isSender,
    this.remoteHash,
  });
}

class RnsFileTransferService {
  final RnsBridge _bridge;
  final StreamController<RnsTransferProgress> _progressController = StreamController<RnsTransferProgress>.broadcast();
  StreamSubscription<RnsBridgeEvent>? _subscription;

  final Map<String, RnsTransferSession> _sessions = {};

  RnsFileTransferService(this._bridge);

  Stream<RnsTransferProgress> get progressStream => _progressController.stream;
  Map<String, RnsTransferSession> get sessions => Map.unmodifiable(_sessions);

  void startListening() {
    _subscription = _bridge.events.listen((event) {
      switch (event.type) {
        case 'session_established':
          _sessions[event.data['session_id'] as String] = RnsTransferSession(
            sessionId: event.data['session_id'] as String,
            isSender: true,
          );
          break;
        case 'transfer_progress':
          _progressController.add(RnsTransferProgress(
            sessionId: event.data['session_id'] as String,
            fileId: event.data['file_id'] as String,
            progress: (event.data['progress'] as num).toDouble(),
          ));
          break;
        case 'session_complete':
        case 'session_error':
        case 'session_cancelled':
        case 'session_declined':
        case 'link_closed':
          _sessions.remove(event.data['session_id'] as String?);
          break;
      }
    });
  }

  Future<void> sendSession(String sessionId, String destHash, List<Map<String, dynamic>> files) async {
    await _bridge.sendSession(sessionId, destHash, files);
  }

  Future<void> acceptSession(String sessionId, Map<String, String> acceptedFiles) async {
    await _bridge.acceptSession(sessionId, acceptedFiles);
  }

  Future<void> declineSession(String sessionId) async {
    await _bridge.declineSession(sessionId);
  }

  Future<void> cancelSession(String sessionId) async {
    await _bridge.cancelSession(sessionId);
  }

  Future<void> sendFile(String sessionId, String filePath, String fileId, String fileName) async {
    await _bridge.sendFile(sessionId, filePath, fileId, fileName);
  }

  void stopListening() {
    _subscription?.cancel();
  }

  void dispose() {
    stopListening();
    _progressController.close();
  }
}
