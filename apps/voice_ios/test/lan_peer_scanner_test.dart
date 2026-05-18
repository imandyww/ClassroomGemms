import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transport/lan_transport.dart';

void main() {
  group('LanPeerScanner.buildSubnetCandidates', () {
    test('keeps preferred IPs first and skips own address', () {
      final candidates = LanPeerScanner.buildSubnetCandidates(
        ['192.168.1.42'],
        preferredIps: ['192.168.1.9', '192.168.1.42'],
      );

      expect(candidates.first, '192.168.1.9');
      expect(candidates, isNot(contains('192.168.1.42')));
      expect(candidates, contains('192.168.1.1'));
    });

    test('ignores non-private IPv4 addresses', () {
      final candidates = LanPeerScanner.buildSubnetCandidates([
        '127.0.0.1',
        '8.8.8.8',
        '192.168.4.25',
      ]);

      expect(candidates, contains('192.168.4.1'));
      expect(
        candidates.any((candidate) => candidate.startsWith('8.8.8.')),
        isFalse,
      );
    });
  });

  group('LanPeerScanner.isPrivateIpv4', () {
    test('matches RFC1918 ranges only', () {
      expect(LanPeerScanner.isPrivateIpv4('10.0.0.5'), isTrue);
      expect(LanPeerScanner.isPrivateIpv4('172.16.1.9'), isTrue);
      expect(LanPeerScanner.isPrivateIpv4('172.31.255.1'), isTrue);
      expect(LanPeerScanner.isPrivateIpv4('192.168.0.10'), isTrue);
      expect(LanPeerScanner.isPrivateIpv4('172.15.1.1'), isFalse);
      expect(LanPeerScanner.isPrivateIpv4('172.32.1.1'), isFalse);
      expect(LanPeerScanner.isPrivateIpv4('8.8.8.8'), isFalse);
      expect(LanPeerScanner.isPrivateIpv4('not-an-ip'), isFalse);
    });
  });
}
