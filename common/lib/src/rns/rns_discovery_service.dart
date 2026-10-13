import 'dart:async';

import 'package:common/model/device.dart';
import 'package:common/src/rns/rns_bridge.dart';
import 'package:logging/logging.dart';

final _logger = Logger('RnsDiscovery');

class RnsDiscoveredPeer {
  final String destinationHash;
  final Map<String, dynamic> appData;

  RnsDiscoveredPeer({
    required this.destinationHash,
    required this.appData,
  });

  Device toDevice() {
    return Device(
      signalingId: null,
      ip: null,
      destinationHash: destinationHash,
      version: appData['version'] as String? ?? '2.1',
      port: 0,
      https: false,
      fingerprint: destinationHash,
      alias: appData['alias'] as String? ?? 'Unknown',
      deviceModel: appData['device_model'] as String?,
      deviceType: DeviceType.desktop,
      download: false,
      discoveryMethods: {},
    );
  }
}

class RnsAnnounceService {
  final RnsBridge _bridge;
  final StreamController<Device> _deviceController = StreamController<Device>.broadcast();
  final StreamController<String> _lostController = StreamController<String>.broadcast();
  StreamSubscription<RnsBridgeEvent>? _subscription;
  bool _listening = false;

  RnsAnnounceService(this._bridge);

  Stream<Device> get deviceStream => _deviceController.stream;

  /// Destination hashes of peers that left the network (password change, shutdown).
  Stream<String> get lostStream => _lostController.stream;
  bool get isListening => _listening;

  void startListening() {
    if (_listening) return;
    _listening = true;

    _subscription = _bridge.events.listen((event) {
      if (event.type == 'peer_lost') {
        final hash = event.data['destination_hash'] as String?;
        if (hash != null) {
          _lostController.add(hash);
          _logger.info('Peer left: ${hash.substring(0, 8)}');
        }
      } else if (event.type == 'peer_discovered') {
        try {
          final peer = RnsDiscoveredPeer(
            destinationHash: event.data['destination_hash'] as String,
            appData: (event.data['app_data'] as Map<String, dynamic>?) ?? {},
          );
          _deviceController.add(peer.toDevice());
          _logger.info('Discovered peer: ${peer.appData['alias']} (${peer.destinationHash.substring(0, 8)})');
        } catch (e) {
          _logger.warning('Failed to process discovered peer', e);
        }
      }
    });
  }

  void stopListening() {
    _subscription?.cancel();
    _listening = false;
  }

  Future<void> sendAnnouncement({required String alias, required String version, String? deviceModel}) async {
    await _bridge.announce({
      'alias': alias,
      'version': version,
      if (deviceModel != null) 'device_model': deviceModel,
    });
    _logger.info('Sent RNS announce for $alias');
  }

  void dispose() {
    stopListening();
    _deviceController.close();
    _lostController.close();
  }
}
