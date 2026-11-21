import 'package:dio/dio.dart';
import 'package:fl_clash/features/v2board/panel_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 单例的代理状态是全局的，测试间要复位。
    PanelEndpoint.instance.markDirectSuccess();
  });

  group('PanelEndpoint 候选域名', () {
    test('顺序是 active → 域名池 → 面板地址，占位符被过滤', () async {
      SharedPreferences.setMockInitialValues({
        'v2b_panel_url': 'https://gettakeoff.cc',
        'v2b_active_domain': 'api.1230654.xyz',
        'v2b_domain_pool': <String>[
          'backup1.dawncdn.com',
          'client.example.invalid',
        ],
      });

      final candidates = await PanelEndpoint.instance.candidates();

      expect(
        candidates,
        [
          'https://api.1230654.xyz',
          'https://backup1.dawncdn.com',
          'https://gettakeoff.cc',
        ],
      );
    });

    test('没有 active 域名时回退到面板地址', () async {
      SharedPreferences.setMockInitialValues({
        'v2b_panel_url': 'https://gettakeoff.cc',
      });

      final candidates = await PanelEndpoint.instance.candidates();

      expect(candidates, ['https://gettakeoff.cc']);
    });
  });

  group('PanelEndpoint 换通道顺序', () {
    test('直连先换备用域名，再换代理（无代理时用完即止）', () async {
      SharedPreferences.setMockInitialValues({
        'v2b_panel_url': 'https://gettakeoff.cc',
        'v2b_active_domain': 'api.1230654.xyz',
        'v2b_domain_pool': <String>['backup1.dawncdn.com'],
      });
      final failed = Uri.parse('https://api.1230654.xyz/api/v1/user/heartbeat');

      final first = await PanelEndpoint.instance.nextAttempt(failed, const []);
      expect(first, isNotNull);
      expect(first!.useProxy, isFalse);
      expect(first.baseUrl, 'https://api.1230654.xyz');
      expect(first.id, 'direct:https://api.1230654.xyz');

      final second = await PanelEndpoint.instance.nextAttempt(
        failed,
        ['direct:https://api.1230654.xyz'],
      );
      expect(second, isNotNull);
      expect(second!.useProxy, isFalse);
      expect(second.baseUrl, 'https://backup1.dawncdn.com');

      final third = await PanelEndpoint.instance.nextAttempt(
        failed,
        [
          'direct:https://api.1230654.xyz',
          'direct:https://backup1.dawncdn.com',
          'direct:https://gettakeoff.cc',
        ],
      );
      // 测试环境没有内核 mixed-port，代理通道不存在 → 没有更多尝试。
      expect(third, isNull);
    });
  });

  group('PanelEndpoint 是否值得换通道', () {
    final options = RequestOptions(path: '/api/v1/user/heartbeat');

    DioException error(
      DioExceptionType type, {
      int? statusCode,
    }) {
      return DioException(
        requestOptions: options,
        type: type,
        response: statusCode == null
            ? null
            : Response<dynamic>(
                requestOptions: options,
                statusCode: statusCode,
              ),
      );
    }

    test('连接层失败 / 超时要换通道', () {
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.connectionError),
        ),
        isTrue,
      );
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.connectionTimeout),
        ),
        isTrue,
      );
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.receiveTimeout),
        ),
        isTrue,
      );
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.unknown),
        ),
        isTrue,
      );
    });

    test('5xx 源站故障要换通道', () {
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.badResponse, statusCode: 502),
        ),
        isTrue,
      );
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.badResponse, statusCode: 504),
        ),
        isTrue,
      );
    });

    test('4xx 业务错误不换通道（换域名也不会变好）', () {
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.badResponse, statusCode: 401),
        ),
        isFalse,
      );
      expect(
        PanelEndpoint.isRetryable(
          error(DioExceptionType.badResponse, statusCode: 422),
        ),
        isFalse,
      );
      expect(
        PanelEndpoint.isRetryable(error(DioExceptionType.cancel)),
        isFalse,
      );
    });
  });
}
