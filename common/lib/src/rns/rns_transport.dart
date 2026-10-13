import 'package:common/src/rns/rns_bridge.dart';
import 'package:common/src/rns/rns_discovery_service.dart';
import 'package:common/src/rns/rns_file_transfer.dart';
import 'package:common/src/rns/rns_config.dart';
import 'package:common/src/rns/rns_identity_manager.dart';

class RnsTransport {
  final RnsBridge bridge;
  final RnsAnnounceService discovery;
  final RnsFileTransferService fileTransfer;
  final RnsIdentityManager identityManager;
  final RnsConfig config;

  RnsTransport({
    required this.bridge,
    required this.discovery,
    required this.fileTransfer,
    required this.identityManager,
    required this.config,
  });

  Future<void> dispose() async {
    fileTransfer.dispose();
    discovery.dispose();
    await bridge.shutdown();
  }
}
