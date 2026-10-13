import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

final _logger = Logger('RnsIdentityManager');

class RnsIdentity {
  final String hash;
  final String publicKey;

  const RnsIdentity({
    required this.hash,
    required this.publicKey,
  });

  String get hashHex => hash;

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'public_key': publicKey,
      };

  factory RnsIdentity.fromJson(Map<String, dynamic> json) {
    return RnsIdentity(
      hash: json['hash'] as String,
      publicKey: json['public_key'] as String,
    );
  }
}

class RnsIdentityManager {
  final String identityPath;

  RnsIdentityManager({required this.identityPath});

  bool get exists => File(identityPath).existsSync();

  Future<void> ensureIdentityDirectory() async {
    final dir = File(identityPath).parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }
}
