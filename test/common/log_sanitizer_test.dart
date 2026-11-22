import 'package:fl_clash/common/log_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeV2BoardLog', () {
    test('订阅 URL 的 token / code / sign / expires / device_id 全部打码', () {
      const text =
          'DioException [unknown]: https://panel.dawnpanel.net/api/v1/client/subscribe'
          '?token=deadbeefcafebabe&flag=meta&app=flclash&device_id=abc123'
          '&code=123456&expires=1763000000&sign=ffffffffffff';
      final sanitized = sanitizeV2BoardLog(text);
      expect(sanitized, contains('token=***'));
      expect(sanitized, contains('code=***'));
      expect(sanitized, contains('expires=***'));
      expect(sanitized, contains('sign=***'));
      expect(sanitized, contains('device_id=***'));
      expect(sanitized, isNot(contains('deadbeefcafebabe')));
      expect(sanitized, isNot(contains('123456')));
    });

    test('保留域名与失败原因，便于排查', () {
      const text = 'DioException [connection error]: '
          'https://panel.dawnpanel.net/api/v1/client/subscribe?token=xxx';
      final sanitized = sanitizeV2BoardLog(text);
      expect(sanitized, contains('panel.dawnpanel.net'));
      expect(sanitized, contains('connection error'));
    });

    test('JSON 错误体里的 subscribe_url 打码成 ***', () {
      const text =
          '{"message":"no","data":{"subscribe_url":"https://x.cc/sub?token=abc"}}';
      final sanitized = sanitizeV2BoardLog(text);
      expect(sanitized, contains('subscribe_url'));
      expect(sanitized, isNot(contains('token=abc')));
    });

    test('设备指纹 mac/disk/guid/deviceId 打码但保留头尾', () {
      const text =
          '[Security] 指纹: mac=AA:BB:CC:DD:EE:FF disk=WD-ABC123456 '
          'guid=12345678-1234-1234-1234-123456789abc';
      final sanitized = sanitizeV2BoardLog(text);
      expect(sanitized, contains('mac='));
      expect(sanitized, contains('***'));
      expect(sanitized, isNot(contains('AA:BB:CC:DD:EE:FF')));
      expect(sanitized, isNot(contains('WD-ABC123456')));
      expect(sanitized, isNot(contains('12345678-1234')));
    });

    test('不含敏感信息的普通文本保持不变', () {
      const text = '[Heartbeat] ok=true status=200 interval=60';
      expect(sanitizeV2BoardLog(text), text);
    });

    test('null / 非字符串异常安全处理', () {
      expect(sanitizeV2BoardLog(null), '');
      expect(sanitizeV2BoardLog(42), '42');
    });
  });

  group('maskSecret', () {
    test('长值保留前 4 后 2', () {
      expect(maskSecret('1234567890abcdef'), '1234***ef');
    });

    test('短值全遮', () {
      expect(maskSecret('short'), '***');
      expect(maskSecret('12345678'), '***');
    });

    test('空值原样返回', () {
      expect(maskSecret(''), '');
    });
  });
}
