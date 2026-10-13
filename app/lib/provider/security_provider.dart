import 'dart:async';
import 'dart:io';

import 'package:common/constants.dart';
import 'package:common/isolate.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:common/src/rns/rns_bridge.dart';
import 'package:common/src/rns/rns_discovery_service.dart';
import 'package:common/src/rns/rns_file_transfer.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('RnsBridgeProvider');

/// This provider manages the [StoredSecurityContext].
/// It contains all the security related data for HTTPS communication.
final securityProvider = ReduxProvider<SecurityService, StoredSecurityContext>(
  (ref) {
    return SecurityService(ref.read(persistenceProvider));
  },
  onChanged: (_, next, ref) {
    ref.redux(parentIsolateProvider).dispatch(IsolateSyncSecurityContextAction(securityContext: next));
  },
);

/// Holds the RNS identity hash separately (avoids mapper regeneration).
final rnsIdentityHashProvider = StateProvider<String?>((ref) => null);

/// Holds the RNS bridge instance (auto-starts on first access).
final rnsBridgeProvider = Provider<RnsBridge>((ref) {
  final bridge = RnsBridge();

  bridge.events.listen((event) {
    if (event.type == 'network_changed') {
      // Peers of the previous network must not stay in the list.
      ref.redux(nearbyDevicesProvider).dispatch(ClearRnsDevicesAction());
    } else if (event.type == 'ready') {
      // Peers address us by destination hash (not identity hash), so that is what we expose.
      final hash = (event.data['destination_hash'] ?? event.data['identity_hash']) as String?;
      if (hash != null) {
        ref.notifier(rnsIdentityHashProvider).setState((_) => hash);
      }
      // Single announce on startup; the bridge re-announces on its own, rate limited.
      final settings = ref.read(settingsProvider);
      unawaited(bridge.announce({
        'alias': settings.alias,
        'version': protocolVersion,
        'device_model': ref.read(deviceInfoProvider).deviceModel,
      }));
    }
  });

  // Auto-start with reasonable defaults for development
  unawaited(_startBridge(bridge, ref.read(persistenceProvider).getRnsPassword()));

  return bridge;
});

/// Holds the RNS announce service for peer discovery.
final rnsAnnounceServiceProvider = Provider<RnsAnnounceService>((ref) {
  final bridge = ref.read(rnsBridgeProvider);
  return RnsAnnounceService(bridge);
});

/// Holds the RNS file transfer service.
final rnsFileTransferServiceProvider = Provider<RnsFileTransferService>((ref) {
  final bridge = ref.read(rnsBridgeProvider);
  return RnsFileTransferService(bridge);
});

const _rnsMethodChannel = MethodChannel('org.localsend.localsend_app/rns');
const _rnsEventChannel = EventChannel('org.localsend.localsend_app/rns_events');

/// Android has no system Python: rns_bridge.py runs in-process (Chaquopy) behind platform channels.
Future<void> _startBridgeAndroid(RnsBridge bridge, String password) async {
  final supportDir = await getApplicationSupportDirectory();
  final cacheDir = await getTemporaryDirectory();

  // Subscribe before starting so no early event is lost.
  final incoming = _rnsEventChannel.receiveBroadcastStream().map((e) => e as String);

  await _rnsMethodChannelStart();
  await bridge.startExternal(
    incoming: incoming,
    write: (line) => unawaited(_rnsMethodChannel.invokeMethod('command', line)),
    configPath: '${supportDir.path}/.reticulum',
    identityPath: '${supportDir.path}/.localsend_reticulum_identity',
    stagingDir: '${cacheDir.path}/localsend_rns_staging',
    password: password,
  );
}

Future<void> _rnsMethodChannelStart() => _rnsMethodChannel.invokeMethod('start');

Future<void> _startBridge(RnsBridge bridge, String password) async {
  if (Platform.isAndroid) {
    try {
      await _startBridgeAndroid(bridge, password);
    } catch (e) {
      _logger.severe('Failed to start embedded RNS bridge: $e');
      bridge.reportError('Failed to start Reticulum: $e');
    }
    return;
  }

  String findBridgeScript() {
    for (final candidate in [
      'rns_bridge.py',
      '../rns_bridge.py',
      '/home/pol/Documents/Projectes/LocalSend-Reticulum/localsend/rns_bridge.py',
      '${File(Platform.resolvedExecutable).parent.path}/rns_bridge.py',
    ]) {
      try {
        if (File(candidate).existsSync()) {
          _logger.info('Found bridge script at: $candidate');
          return File(candidate).absolute.path;
        }
      } catch (_) {}
    }
    _logger.severe('Bridge script not found in any location');
    return 'rns_bridge.py';
  }

  String findPython() {
    for (final candidate in ['python3', 'python']) {
      try {
        final result = Process.runSync(candidate, ['--version']);
        if (result.exitCode == 0) {
          _logger.info('Using Python: $candidate (${result.stdout.toString().trim()})');
          return candidate;
        }
      } catch (_) {}
    }
    _logger.severe('No Python executable found');
    return 'python3';
  }

  // HOME does not exist on Windows.
  final homeDir = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;

  await bridge.start(
    pythonPath: findPython(),
    bridgeScriptPath: findBridgeScript(),
    configPath: '$homeDir/.reticulum',
    identityPath: '$homeDir/.localsend_reticulum_identity',
    stagingDir: '${Directory.systemTemp.path}/localsend_rns_staging',
    password: password,
  );
}

class SecurityService extends ReduxNotifier<StoredSecurityContext> {
  final PersistenceService _persistence;

  SecurityService(this._persistence);

  @override
  StoredSecurityContext init() {
    return _persistence.getSecurityContext();
  }
}

/// Generates a new [StoredSecurityContext] and persists it.
class ResetSecurityContextAction extends AsyncReduxAction<SecurityService, StoredSecurityContext> {
  @override
  Future<StoredSecurityContext> reduce() async {
    final securityContext = generateSecurityContext();
    await notifier._persistence.setSecurityContext(securityContext);
    return securityContext;
  }
}
