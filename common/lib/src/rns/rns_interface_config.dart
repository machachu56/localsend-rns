class RnsInterfaceConfig {
  final String name;
  final String type;
  final bool enabled;
  final String? targetHost;
  final String? targetPort;
  final String? listenPort;
  final List<String>? peers;

  const RnsInterfaceConfig({
    required this.name,
    this.type = 'TCPClientInterface',
    this.enabled = true,
    this.targetHost,
    this.targetPort,
    this.listenPort,
    this.peers,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'enabled': enabled,
        if (targetHost != null) 'target_host': targetHost,
        if (targetPort != null) 'target_port': targetPort,
        if (listenPort != null) 'listen_port': listenPort,
        if (peers != null) 'peers': peers,
      };

  factory RnsInterfaceConfig.fromJson(Map<String, dynamic> json) {
    return RnsInterfaceConfig(
      name: json['name'] as String,
      type: json['type'] as String? ?? 'TCPClientInterface',
      enabled: json['enabled'] as bool? ?? true,
      targetHost: json['target_host'] as String?,
      targetPort: json['target_port'] as String?,
      listenPort: json['listen_port'] as String?,
      peers: json['peers'] != null ? List<String>.from(json['peers'] as List) : null,
    );
  }

  RnsInterfaceConfig copyWith({
    String? name,
    String? type,
    bool? enabled,
    String? targetHost,
    String? targetPort,
    String? listenPort,
    List<String>? peers,
  }) {
    return RnsInterfaceConfig(
      name: name ?? this.name,
      type: type ?? this.type,
      enabled: enabled ?? this.enabled,
      targetHost: targetHost ?? this.targetHost,
      targetPort: targetPort ?? this.targetPort,
      listenPort: listenPort ?? this.listenPort,
      peers: peers ?? this.peers,
    );
  }
}
