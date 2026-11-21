import 'package:fl_clash/features/network/system_ipv6.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SystemIpv6Status', () {
    test('enabled when adapter is up, binding on and registry allows IPv6', () {
      const status = SystemIpv6Status(
        registryDisabled: false,
        bindingEnabled: true,
        hasAdapter: true,
      );
      expect(status.enabled, isTrue);
      expect(status.disabled, isFalse);
    });

    test('disabled when the registry blocks IPv6', () {
      const status = SystemIpv6Status(
        registryDisabled: true,
        bindingEnabled: true,
        hasAdapter: true,
      );
      expect(status.enabled, isFalse);
      expect(status.disabled, isTrue);
    });

    test('disabled when every adapter has the binding off', () {
      const status = SystemIpv6Status(
        registryDisabled: false,
        bindingEnabled: false,
        hasAdapter: true,
      );
      expect(status.enabled, isFalse);
      expect(status.disabled, isTrue);
    });

    test('neither enabled nor disabled when no adapter is up or inspect failed', () {
      const noAdapter = SystemIpv6Status(
        registryDisabled: false,
        bindingEnabled: false,
        hasAdapter: false,
      );
      expect(noAdapter.enabled, isFalse);
      expect(noAdapter.disabled, isFalse);

      const failed = SystemIpv6Status(
        registryDisabled: false,
        bindingEnabled: false,
        hasAdapter: false,
        error: 'powershell unavailable',
      );
      expect(failed.enabled, isFalse);
      expect(failed.disabled, isFalse);
    });
  });
}
