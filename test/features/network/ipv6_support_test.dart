import 'package:fl_clash/features/network/ipv6_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Ipv6Support.isLinkLocal', () {
    test('recognizes fe80::/10 addresses', () {
      expect(Ipv6Support.isLinkLocal('fe80::1'), isTrue);
      expect(Ipv6Support.isLinkLocal('FE80::1'), isTrue);
      expect(Ipv6Support.isLinkLocal('fe80::a00:27ff:fe4e:66a1'), isTrue);
      expect(Ipv6Support.isLinkLocal('febf:ffff::1'), isTrue);
      expect(Ipv6Support.isLinkLocal('fe80:0000:0000:0000:0000:0000:0000:0001'), isTrue);
    });

    test('rejects global and non mappable addresses', () {
      expect(Ipv6Support.isLinkLocal('2001:db8::1'), isFalse);
      expect(Ipv6Support.isLinkLocal('2400:3200::1'), isFalse);
      expect(Ipv6Support.isLinkLocal('fec0::1'), isFalse);
      expect(Ipv6Support.isLinkLocal('::1'), isFalse);
      expect(Ipv6Support.isLinkLocal(''), isFalse);
      expect(Ipv6Support.isLinkLocal('not-an-address'), isFalse);
    });

    test('ignores surrounding whitespace', () {
      expect(Ipv6Support.isLinkLocal('  fe80::1  '), isTrue);
    });
  });

  group('Ipv6Probe.usable', () {
    test('requires both a global address and a working connection', () {
      expect(
        const Ipv6Probe(systemEnabled: true, reachable: true).usable,
        isTrue,
      );
      expect(
        const Ipv6Probe(systemEnabled: false, reachable: true).usable,
        isFalse,
      );
      expect(
        const Ipv6Probe(systemEnabled: true, reachable: false).usable,
        isFalse,
      );
      expect(
        const Ipv6Probe(systemEnabled: false, reachable: false).usable,
        isFalse,
      );
    });
  });
}
