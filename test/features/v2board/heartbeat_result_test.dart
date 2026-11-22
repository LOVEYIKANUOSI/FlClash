import 'package:fl_clash/features/v2board/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('心跳 403 分类（H-09）', () {
    V2BoardHeartbeatResult result({int? status, String? message}) {
      return V2BoardHeartbeatResult(
        ok: false,
        statusCode: status,
        message: message,
      );
    }

    test('JWT 过期（面板中间件 403 + 固定文案）走静默重登', () {
      // 面板 User 中间件对过期 token 返回 403 + 「未登录或登陆已过期」，
      // 不是设备问题，必须继续静默重登（面板 JWT 只活 2 小时）。
      final r = result(status: 403, message: '未登录或登陆已过期');
      expect(r.isAuthExpired, isTrue);
      expect(r.isDeviceRevoked, isFalse);
    });

    test('设备吊销（403 + device 文案）提示设备受限', () {
      final r = result(status: 403, message: 'device not found or revoked');
      expect(r.isAuthExpired, isFalse);
      expect(r.isDeviceRevoked, isTrue);
    });

    test('中文设备文案同样识别为设备受限', () {
      final r = result(status: 403, message: '设备已被限制，请联系客服');
      expect(r.isDeviceRevoked, isTrue);
      expect(r.isAuthExpired, isFalse);
    });

    test('401 永远算登录过期', () {
      expect(result(status: 401).isAuthExpired, isTrue);
      expect(result(status: 401).isDeviceRevoked, isFalse);
    });

    test('无文案的 403 保守按登录过期处理（静默重登无害）', () {
      final r = result(status: 403);
      expect(r.isAuthExpired, isTrue);
      expect(r.isDeviceRevoked, isFalse);
    });
  });
}
