import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'constants.dart';
import 'device_identity.dart';
import 'peer.dart';

/// UDP multicast discovery. Sends / listens for small JSON packets on
/// 224.0.0.167:53317 so peers on the same LAN can find each other without
/// needing a known IP.
class MulticastService {
  final DeviceIdentity identity;
  final void Function(LanPeer peer)? onPeer;
  RawDatagramSocket? _socket;
  Timer? _announceTimer;

  MulticastService({required this.identity, this.onPeer});

  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanConst.port,
        reuseAddress: true,
        reusePort: true,
      );
      _socket!.broadcastEnabled = true;
      try {
        _socket!.joinMulticast(InternetAddress(LanConst.multicastGroup));
      } catch (e) {
        debugPrint('multicast: joinMulticast failed: $e (discovery will still accept unicast announcements)');
      }

      _socket!.listen(_onEvent);

      _announceTimer = Timer.periodic(const Duration(seconds: 5), (_) => announce());
      announce();
    } catch (e) {
      debugPrint('multicast: bind failed: $e');
      rethrow;
    }
  }

  void stop() {
    _announceTimer?.cancel();
    _announceTimer = null;
    _socket?.close();
    _socket = null;
  }

  void announce() {
    final s = _socket;
    if (s == null) return;
    final payload = utf8.encode(jsonEncode(_selfDto()));
    try {
      s.send(payload, InternetAddress(LanConst.multicastGroup), LanConst.port);
    } catch (e) {
      debugPrint('multicast: send failed: $e');
    }
  }

  Map<String, dynamic> _selfDto() => {
        'alias': identity.alias,
        'fingerprint': identity.fingerprint,
        'port': LanConst.port,
        'protocol': LanConst.protocol,
        'deviceType': DeviceIdentity.deviceType(),
        'version': LanConst.protocolVersion,
        'announce': true,
      };

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    try {
      final json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      final fingerprint = json['fingerprint'] as String?;
      if (fingerprint == null || fingerprint == identity.fingerprint) return;
      final peer = LanPeer(
        alias: (json['alias'] as String?) ?? 'unknown',
        fingerprint: fingerprint,
        ip: dg.address.address,
        port: (json['port'] as num?)?.toInt() ?? LanConst.port,
        deviceType: (json['deviceType'] as String?) ?? 'unknown',
        lastSeen: DateTime.now(),
      );
      onPeer?.call(peer);
    } catch (_) {
      // ignore malformed
    }
  }
}
