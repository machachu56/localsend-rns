import 'package:path/path.dart' as p;

class RnsConfig {
  static const appName = 'localesnd-reticulum';
  static const transferAspect = 'transfer';

  static const defaultPort = 53317;
  static const defaultMulticastGroup = '224.0.0.167';

  static String get defaultConfigPath {
    return p.join('~', '.reticulum');
  }

  static String get defaultIdentityPath {
    return p.join('~', '.localsend_reticulum_identity');
  }

  static String get defaultStagingDir {
    return '/tmp/localsend_rns_staging';
  }
}
