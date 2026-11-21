import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/features/update/update_client.dart';
import 'package:fl_clash/features/update/update_verify.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用「服务端真实输出」（`client_update_fixture.json`，由本地面板
/// `client:update:add --publish` + `ClientUpdateService::manifest()` 生成，
/// 带真实 RSA 签名）校验客户端能否正确请求 / 解析 / 验签。
void main() {
  late HttpServer server;
  late String baseUrl;
  late String fixtureBody;
  late Map<String, String> lastQuery;
  late String lastAuthorization;
  late int statusCode;

  setUp(() async {
    fixtureBody =
        File('test/features/update/client_update_fixture.json').readAsStringSync();
    statusCode = 200;
    lastQuery = {};
    lastAuthorization = '';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      lastAuthorization =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      lastQuery = request.uri.queryParameters;
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.write(fixtureBody);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('fetches panel manifest, parses fields and verifies real signature',
      () async {
    final manifest = await UpdateClient.instance.fetchFromPanel(
      baseUrl: baseUrl,
      authData: 'test-auth-data',
      currentCode: 2026111900,
    );

    expect(manifest, isNotNull);
    expect(manifest!.versionName, '0.9.4');
    expect(manifest.versionCode, 2026111901);
    expect(manifest.minVersionCode, 0);
    expect(manifest.fileName, 'dawn-fixed.exe');
    expect(manifest.fileSize, 17);
    expect(
      manifest.sha256,
      '9e1c2a78532514251baf7a525f4c493fd4520b5f0d7cd363e412cdd7a657efa9',
    );
    expect(manifest.downloadUrl, 'https://dl.example.com/dawn/Dawn-0.9.4-setup.exe');
    expect(manifest.mandatory, isFalse);
    expect(manifest.hasSignature, isTrue);

    // 服务端签名原文 + 客户端拼出来的一模一样，并且能验通。
    expect(
      manifest.signaturePayload,
      'dawn-update-v1\nwindows-x64\n2026111901\n17\n'
      '9e1c2a78532514251baf7a525f4c493fd4520b5f0d7cd363e412cdd7a657efa9',
    );
    expect(
      verifyUpdateSignature(
        payload: manifest.signaturePayload,
        signature: manifest.signature,
      ),
      isTrue,
    );

    // 请求本身：路径、鉴权头、三个查询参数。
    expect(lastAuthorization, 'test-auth-data');
    expect(lastQuery['platform'], 'windows-x64');
    expect(lastQuery['channel'], 'stable');
    expect(lastQuery['code'], '2026111900');
  });

  test('data:null means already up to date', () async {
    fixtureBody = jsonEncode({'data': null});
    final manifest = await UpdateClient.instance.fetchFromPanel(
      baseUrl: baseUrl,
      authData: 'test-auth-data',
      currentCode: 2026111901,
    );
    expect(manifest, isNull);
  });

  test('401/403 maps to UpdateCheckUnauthorized', () async {
    statusCode = 403;
    fixtureBody = jsonEncode({'message': '未登录或登陆已过期'});
    await expectLater(
      UpdateClient.instance.fetchFromPanel(
        baseUrl: baseUrl,
        authData: 'expired',
        currentCode: 2026111900,
      ),
      throwsA(isA<UpdateCheckUnauthorized>()),
    );
  });

  test('non-200 status throws so caller can fall back to GitHub', () async {
    statusCode = 404;
    fixtureBody = jsonEncode({'message': 'not found'});
    await expectLater(
      UpdateClient.instance.fetchFromPanel(
        baseUrl: baseUrl,
        authData: 'test-auth-data',
        currentCode: 2026111900,
      ),
      throwsA(isA<DioException>()),
    );
  });
}
