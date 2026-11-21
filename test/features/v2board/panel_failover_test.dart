import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只对 [allowedHosts] 放行的假适配器；其它 host 按「连接被拒」处理。
class _FakeAdapter implements HttpClientAdapter {
  final Set<String> allowedHosts;
  final List<String> calls = [];

  _FakeAdapter(this.allowedHosts);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.uri.host);
    if (!allowedHosts.contains(options.uri.host)) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'connection refused',
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'data': {'auth_data': 'jwt-from-backup', 'token': 'token-from-backup'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('主域名不可达时自动换面板下发的备用域名', () async {
    SharedPreferences.setMockInitialValues({
      'v2b_panel_url': 'https://gettakeoff.cc',
      'v2b_active_domain': 'api.primary-dawn.com',
      'v2b_domain_pool': <String>[
        'api.primary-dawn.com',
        'backup1.dawncdn.com',
      ],
    });
    final adapter = _FakeAdapter({'backup1.dawncdn.com'});
    v2BoardClient.debugSetHttpClientAdapter(adapter);

    final result = await v2BoardClient.login(
      baseUrl: 'https://api.primary-dawn.com',
      email: 'a@b.com',
      password: 'password123',
    );

    expect(result.authData, 'jwt-from-backup');
    // 先试主域名，失败后换备用域名成功。
    expect(adapter.calls, ['api.primary-dawn.com', 'backup1.dawncdn.com']);
  });

  test('所有通道都不可达时抛 isNetwork 异常（不当作账号错误）', () async {
    SharedPreferences.setMockInitialValues({
      'v2b_panel_url': 'https://gettakeoff.cc',
      'v2b_active_domain': 'api.primary-dawn.com',
      'v2b_domain_pool': <String>['backup1.dawncdn.com'],
    });
    final adapter = _FakeAdapter({});
    v2BoardClient.debugSetHttpClientAdapter(adapter);

    await expectLater(
      v2BoardClient.login(
        baseUrl: 'https://api.primary-dawn.com',
        email: 'a@b.com',
        password: 'password123',
      ),
      throwsA(
        isA<V2BoardException>()
            .having((e) => e.isNetwork, 'isNetwork', isTrue)
            .having((e) => e.statusCode, 'statusCode', isNull),
      ),
    );
    // 三个候选（active / 备用 / 面板地址）都试过。
    expect(adapter.calls.length, greaterThanOrEqualTo(2));
  });
}
