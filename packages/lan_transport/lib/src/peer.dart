class LanPeer {
  final String alias;
  final String fingerprint;
  final String ip;
  final int port;
  final String deviceType;
  final DateTime lastSeen;

  const LanPeer({
    required this.alias,
    required this.fingerprint,
    required this.ip,
    required this.port,
    required this.deviceType,
    required this.lastSeen,
  });

  String get baseUrl => 'http://$ip:$port';

  LanPeer copyWith({String? ip, DateTime? lastSeen}) => LanPeer(
        alias: alias,
        fingerprint: fingerprint,
        ip: ip ?? this.ip,
        port: port,
        deviceType: deviceType,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'fingerprint': fingerprint,
        'ip': ip,
        'port': port,
        'deviceType': deviceType,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory LanPeer.fromJson(Map<String, dynamic> j) => LanPeer(
        alias: j['alias'] as String,
        fingerprint: j['fingerprint'] as String,
        ip: j['ip'] as String,
        port: (j['port'] as num).toInt(),
        deviceType: j['deviceType'] as String? ?? 'unknown',
        lastSeen: DateTime.tryParse(j['lastSeen'] as String? ?? '') ?? DateTime.now(),
      );
}
