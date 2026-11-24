import 'package:fl_clash/common/dns_protection.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isEncryptedDnsServer', () {
    test('recognizes DoH/DoT/DoQ and rejects plain servers', () {
      expect(isEncryptedDnsServer('https://doh.pub/dns-query'), isTrue);
      expect(isEncryptedDnsServer('tls://8.8.4.4'), isTrue);
      expect(isEncryptedDnsServer('quic://dns.adguard.com'), isTrue);
      expect(isEncryptedDnsServer('223.5.5.5'), isFalse);
      expect(isEncryptedDnsServer('system://'), isFalse);
      expect(isEncryptedDnsServer(null), isFalse);
    });
  });

  group('applyDnsLeakProtection', () {
    test('replaces plain-text nameservers with encrypted DNS', () {
      final dns = applyDnsLeakProtection(
        dns: <String, dynamic>{
          'enable': true,
          'enhanced-mode': 'fake-ip',
          'nameserver': ['223.5.5.5', '119.29.29.29', 'system://'],
          'fallback': ['1.1.1.1'],
        },
        overriddenKeys: const <DnsOverrideKey>{},
      );
      expect(dns['nameserver'], contains('https://doh.pub/dns-query'));
      expect(dns['fallback'], contains('https://1.1.1.1/dns-query'));
      expect(dns['fallback'], contains('https://8.8.8.8/dns-query'));
      expect(dns['default-nameserver'], contains('223.5.5.5'));
      expect(dns['proxy-server-nameserver'], contains('223.5.5.5'));
      expect(dns['fallback-filter'], containsPair('geoip', true));
      expect(dns['fallback-filter'], containsPair('geoip-code', 'CN'));
      // DNS 查询跟随规则（国外 DoH 经代理发出），这是防泄露的关键。
      expect(dns['respect-rules'], isTrue);
      // 其它字段保留
      expect(dns['enhanced-mode'], 'fake-ip');
    });

    test('keeps an encrypted nameserver untouched', () {
      final original = <String, dynamic>{
        'nameserver': ['https://dns.example/dns-query'],
      };
      final dns = applyDnsLeakProtection(
        dns: original,
        overriddenKeys: const <DnsOverrideKey>{},
      );
      expect(dns, same(original));
    });

    test('never binds the remote DoH to a proxy group', () {
      // Dart 侧拿不到 proxy-groups（内核把 bulk section 留在内核里），
      // 因此不能生成 `#PROXY` 这类后缀，否则内核会拒绝加载。
      final dns = applyDnsLeakProtection(
        dns: <String, dynamic>{},
        overriddenKeys: const <DnsOverrideKey>{},
      );
      expect(
        (dns['fallback'] as List).any((item) => item.toString().contains('#')),
        isFalse,
      );
    });

    test('does not override an explicit user selection', () {
      final original = <String, dynamic>{'nameserver': ['223.5.5.5']};
      final dns = applyDnsLeakProtection(
        dns: original,
        overriddenKeys: const <DnsOverrideKey>{DnsOverrideKey.nameserver},
      );
      expect(dns, same(original));
    });

    test('can be disabled globally', () {
      final original = <String, dynamic>{'nameserver': ['223.5.5.5']};
      final dns = applyDnsLeakProtection(
        dns: original,
        overriddenKeys: const <DnsOverrideKey>{},
        enabled: false,
      );
      expect(dns, same(original));
    });
  });
}
