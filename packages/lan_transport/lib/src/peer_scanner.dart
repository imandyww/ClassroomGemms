import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'constants.dart';
import 'peer.dart';

class LanScanSummary {
  final List<LanPeer> peers;
  final int scannedHostCount;
  final int permissionDeniedCount;

  const LanScanSummary({
    required this.peers,
    required this.scannedHostCount,
    required this.permissionDeniedCount,
  });
}

class LanPeerScanner {
  final Duration connectionTimeout;
  final Duration requestTimeout;
  final int batchSize;

  const LanPeerScanner({
    this.connectionTimeout = const Duration(milliseconds: 500),
    this.requestTimeout = const Duration(milliseconds: 900),
    this.batchSize = 24,
  });

  Future<LanScanSummary> scanLocalSubnets({
    Iterable<String> preferredIps = const [],
  }) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final localIps = interfaces
        .expand((iface) => iface.addresses)
        .map((address) => address.address);
    final candidates = buildSubnetCandidates(
      localIps,
      preferredIps: preferredIps,
    );
    return scanIps(candidates);
  }

  Future<LanScanSummary> scanIps(Iterable<String> ips) async {
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    final peersByFingerprint = <String, LanPeer>{};
    var scannedHostCount = 0;
    var permissionDeniedCount = 0;

    try {
      final candidates = ips.toList(growable: false);
      for (var start = 0; start < candidates.length; start += batchSize) {
        final end = (start + batchSize < candidates.length)
            ? start + batchSize
            : candidates.length;
        final batch = candidates.sublist(start, end);
        final results = await Future.wait(
          batch.map((ip) => _probe(client, ip)),
          eagerError: false,
        );
        scannedHostCount += batch.length;
        for (final result in results) {
          if (result.permissionDenied) {
            permissionDeniedCount++;
            continue;
          }
          final peer = result.peer;
          if (peer == null) continue;
          peersByFingerprint[peer.fingerprint] = peer;
        }

        if (peersByFingerprint.values.any(
          (peer) => peer.acceptsIntents && peer.deviceType == 'desktop',
        )) {
          break;
        }
      }
    } finally {
      client.close(force: true);
    }

    return LanScanSummary(
      peers: peersByFingerprint.values.toList(growable: false),
      scannedHostCount: scannedHostCount,
      permissionDeniedCount: permissionDeniedCount,
    );
  }

  static List<String> buildSubnetCandidates(
    Iterable<String> localIps, {
    Iterable<String> preferredIps = const [],
  }) {
    final ownIps = localIps.where(isPrivateIpv4).toSet();
    final ordered = <String>{};

    // Co-located case: the teacher Mac and the student (iOS Simulator) may
    // share the host. The teacher's HTTP server is then reachable at
    // loopback, and its public IPs collide with ours. Probe loopback first
    // and DO NOT exclude own IPs below — the caller is expected to filter
    // self-fingerprint matches.
    ordered.add('127.0.0.1');

    for (final ip in preferredIps) {
      if (isPrivateIpv4(ip)) {
        ordered.add(ip);
      }
    }

    for (final ip in ownIps) {
      final octets = ip.split('.');
      if (octets.length != 4) continue;
      final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
      for (var host = 1; host < 255; host++) {
        ordered.add('$prefix.$host');
      }
    }

    return ordered.toList(growable: false);
  }

  static bool isPrivateIpv4(String ip) {
    final octets = ip.split('.');
    if (octets.length != 4) return false;
    final first = int.tryParse(octets[0]);
    final second = int.tryParse(octets[1]);
    if (first == null || second == null) return false;
    if (first == 10) return true;
    if (first == 192 && second == 168) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    return false;
  }

  Future<_ProbeResult> _probe(HttpClient client, String ip) async {
    final uri = Uri.parse('http://$ip:${LanConst.port}${LanConst.infoPath}');
    try {
      final request = await client.getUrl(uri).timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != 200) {
        return const _ProbeResult();
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(requestTimeout);
      final json = jsonDecode(body) as Map<String, dynamic>;
      return _ProbeResult(
        peer: LanPeer(
          alias: (json['alias'] as String?) ?? 'Mac@$ip',
          fingerprint: (json['fingerprint'] as String?) ?? 'scan-$ip',
          ip: ip,
          port: (json['port'] as num?)?.toInt() ?? LanConst.port,
          deviceType: (json['deviceType'] as String?) ?? 'desktop',
          acceptsIntents: (json['acceptsIntents'] as bool?) ?? true,
          lastSeen: DateTime.now(),
        ),
      );
    } on TimeoutException {
      return const _ProbeResult();
    } catch (error) {
      return _ProbeResult(permissionDenied: _looksLikePermissionDenied(error));
    }
  }

  static bool _looksLikePermissionDenied(Object error) {
    if (error is! SocketException) return false;
    final code = error.osError?.errorCode;
    final message = '${error.message} ${error.osError?.message}'.toLowerCase();
    return code == 1 ||
        message.contains('operation not permitted') ||
        message.contains('permission denied');
  }
}

class _ProbeResult {
  final LanPeer? peer;
  final bool permissionDenied;

  const _ProbeResult({this.peer, this.permissionDenied = false});
}
