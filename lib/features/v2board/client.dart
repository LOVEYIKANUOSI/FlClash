import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:flutter/foundation.dart';

import 'app_config.dart';
import 'panel_endpoint.dart';
import 'totp.dart';

/// 面板 403 文案分类（H-09）。
///
/// 面板 `User` 中间件对无效/过期 JWT 返回 403 + 「未登录或登陆已过期」，
/// 而设备吊销返回 403 + `device not found or revoked` / 「设备已被限制」。
/// 两者状态码相同，只能靠文案区分：JWT 过期应静默重登，设备问题应提示用户。
bool _isDeviceRejectionMessage(String? message) {
  if (message == null || message.isEmpty) {
    return false;
  }
  final text = message.toLowerCase();
  return text.contains('device') ||
      text.contains('revoked') ||
      text.contains('设备') ||
      text.contains('禁用') ||
      text.contains('限制') ||
      text.contains('上限');
}

/// V2Board 接口调用失败时抛出，message 直接展示给用户。
class V2BoardException implements Exception {
  final String message;
  final int? statusCode;

  /// 网络/面板不可达类失败（不是账号或业务错误）。
  ///
  /// 登录链路据此区分「面板暂时挂了」和「账号密码错了」：前者绝不能清会话
  /// 或把用户踢回登录页，否则面板抖一下全体客户端掉线。
  final bool isNetwork;

  const V2BoardException(
    this.message, {
    this.statusCode,
    this.isNetwork = false,
  });

  /// JWT 失效：面板 `User`/`Staff` 中间件对无效/过期 token 一律返回
  /// **403 + 「未登录或登陆已过期」**（不是 401），所以必须结合 message 判断（H-09）。
  bool get isAuthExpired =>
      statusCode == 401 ||
      (statusCode == 403 && !_isDeviceRejectionMessage(message));

  /// 设备被吊销/未知：心跳接口在 JWT 通过后仍 403，message 为
  /// `device not found or revoked`（`UserDeviceController::heartbeat`）。
  bool get isDeviceRevoked =>
      statusCode == 403 && _isDeviceRejectionMessage(message);

  @override
  String toString() => message;
}

class V2BoardLoginResult {
  final String authData;
  final String token;

  const V2BoardLoginResult({required this.authData, required this.token});
}

class V2BoardHeartbeatResult {
  final bool ok;
  final int? intervalSeconds;
  final int? statusCode;

  /// H-08：面板可以在心跳响应里下发当前接入域名与域名池（与注册接口一致）。
  /// 字段为空表示面板没下发（旧版面板），调用方保持现有域名配置。
  final String? active;
  final List<String> domainPool;

  /// 面板返回的 `message`（403 时用来判断是「设备被吊销」还是别的业务错误）。
  final String? message;

  const V2BoardHeartbeatResult({
    required this.ok,
    this.intervalSeconds,
    this.statusCode,
    this.active,
    this.domainPool = const <String>[],
    this.message,
  });

  /// JWT 失效（面板 `user` 中间件对过期 token 返回 403 + 「未登录或登陆已过期」）。
  /// 面板 JWT 默认只活 2 小时，这是常态过期，应静默重登（H-09）。
  bool get isAuthExpired =>
      statusCode == 401 ||
      (statusCode == 403 && !_isDeviceRejectionMessage(message));

  /// 设备被吊销/未知（面板心跳在 JWT 通过后仍 403 + `device not found or revoked`）。
  bool get isDeviceRevoked =>
      statusCode == 403 && _isDeviceRejectionMessage(message);

  /// 需要重新登录（兼容旧调用方）。
  bool get isUnauthorized => isAuthExpired;
}

class V2BoardDomainReportResult {
  final String? active;
  final List<String> domainPool;

  const V2BoardDomainReportResult({this.active, required this.domainPool});
}

/// V2Board 面板 HTTP 客户端。
///
/// 与后端约定（见 docs/client-api.md）：
/// - 登录：POST /api/v1/passport/auth/login → data.auth_data / data.token
/// - 设备注册：POST /api/v1/user/device/register → data.device_id/totp_secret/...
/// - 普通订阅：GET /api/v1/user/getSubscribe → data.subscribe_url
///   （生产 subscribe_path 随机化，订阅地址必须用面板下发的，不能自己拼）
/// - 专属订阅：在上面 URL 追加 device_id/code/expires/sign（见 totp.dart）
/// - 心跳：POST /api/v1/user/heartbeat → data.heartbeat_interval
/// - 域名上报：POST /api/v1/user/reportDomain → data.active/domain_pool
class V2BoardClient {
  V2BoardClient._() {
    // 面板请求的多通道容灾：失败自动换备用域名 → 再换用户节点代理。
    // 挂在拦截器层，所有接口（登录/心跳/订阅/商城/工单）自动生效。
    _dio.interceptors.add(
      PanelFailoverInterceptor(
        directDio: () => _dio,
        proxyDio: () => PanelEndpoint.instance.proxyDio,
      ),
    );
  }

  static final V2BoardClient instance = V2BoardClient._();

  final Dio _dio = Dio(
    BaseOptions(
      headers: {'User-Agent': browserUa, 'Accept': 'application/json'},
      responseType: ResponseType.json,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      // 面板的业务错误用非 200 表达，统一交给 _requireDataMap 解析 message。
      validateStatus: (status) => status != null,
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
      // S-37：面板请求（登录/心跳/订阅/商城/工单）必须校验证书，
      // 不受设置里「校验 TLS 证书」用户开关的影响。
      createHttpClient: () =>
          HttpClient()..badCertificateCallback = ((_, _, _) => false),
    );

  String _buildUrl(String baseUrl, String path) {
    return '${AppConfig.normalizeUrl(baseUrl)}$path';
  }

  /// 仅测试用：替换底层 HTTP 适配器，模拟主域名不可达 / 备用域名可用。
  @visibleForTesting
  void debugSetHttpClientAdapter(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
  }

  /// 登录，返回 auth_data（后续请求的 Authorization 头）和 token。
  Future<V2BoardLoginResult> login({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        _buildUrl(baseUrl, AppConfig.loginPath),
        data: {'email': email.trim(), 'password': password},
      );
    } on DioException {
      // 直连 + 备用域名 + 节点代理全部失败才算「面板不可达」。
      // 这类失败不能清会话/踢登录页（面板短时故障不该让所有客户端掉线）。
      throw const V2BoardException(
        '面板暂时无法连接，请检查网络后重试',
        isNetwork: true,
      );
    }
    final data = _requireDataMap(response, fallbackMessage: '登录失败');
    final authData = data['auth_data']?.toString();
    final token = data['token']?.toString();
    if (authData == null || authData.isEmpty) {
      throw const V2BoardException('登录失败：面板未返回 auth_data');
    }
    return V2BoardLoginResult(authData: authData, token: token ?? '');
  }

  /// 校验当前登录态是否仍然有效。
  ///
  /// 三态返回：
  /// - `true`：面板确认已登录
  /// - `false`：面板明确说未登录（401/403，token 失效或被踢）
  /// - `null`：**无法判断**（超时、断网、5xx、域名失效）——调用方必须沿用本地
  ///   会话，不能据此把人踢回登录页。历史上这里把异常一律当成 false，
  ///   网络一抖就清会话，是「登录太频繁」的主要原因之一。
  Future<bool?> checkLogin(String baseUrl, String authData) async {
    try {
      final response = await _dio.get<dynamic>(
        _buildUrl(baseUrl, AppConfig.checkLoginPath),
        options: Options(headers: {'Authorization': authData}),
      );
      final data = _requireDataMap(response, fallbackMessage: '检查登录状态失败');
      return data['is_login'] == true;
    } on V2BoardException catch (e) {
      // _dio 的 validateStatus 接受所有状态码，401/403 不会抛 DioException，
      // 而是由 _requireDataMap 转成 V2BoardException —— 必须在这里判断，
      // 否则 token 过期会被当成网络异常（null），一直沿用旧会话。
      if (e.statusCode == 401 || e.statusCode == 403) {
        return false;
      }
      return null;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return false;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 拉取普通订阅信息（含面板返回的 subscribe_url）。
  Future<Map<String, dynamic>?> getSubscribe(
    String baseUrl,
    String authData,
  ) async {
    try {
      final response = await _dio.get<dynamic>(
        _buildUrl(baseUrl, '/api/v1/user/getSubscribe'),
        options: Options(headers: {'Authorization': authData}),
      );
      final data = _requireDataMap(response, fallbackMessage: '获取订阅信息失败');
      return data;
    } catch (_) {
      return null;
    }
  }

  /// 设备注册：带回硬件指纹与环境画像，面板会下发 device_id / totp_secret /
  /// heartbeat_interval / active / domain_pool。
  Future<Map<String, dynamic>?> registerDevice(
    String baseUrl,
    String authData, {
    required String mac,
    required String diskSerial,
    required String machineGuid,
    Map<String, dynamic>? profile,
  }) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, AppConfig.deviceRegisterPath),
      data: {
        'mac': mac,
        'disk_serial': diskSerial,
        'machine_guid': machineGuid,
        'profile': ?profile,
      },
      options: Options(headers: {'Authorization': authData}),
    );
    final data = _requireDataMap(response, fallbackMessage: '设备注册失败');
    // H-12：不要用 `data['active'] == false` 判断设备被限制 —— 面板的 `active`
    // 字段是「当前接入域名」（字符串），设备禁用/超限走非 200 + 403 语义，
    // 由 _requireDataMap 抛 V2BoardException(statusCode: 403)。
    return data;
  }

  /// 面板 `/api/v1/user/appSubscribe` 下发的设备订阅链接。
  ///
  /// ⚠️ 它带 `app=flclash&device_id` 但**没有 code/expires/sign**，直接拿去拉订阅
  /// 会被 `verifyAppSubscribe` 403。专属订阅实际由 [Totp.buildSignedSubscribeUrl]
  /// 在 `getSubscribe` 下发的普通链接上追加签名参数生成，此方法仅保留接口完整性。
  Future<String?> appSubscribe(
    String baseUrl,
    String authData, {
    required String deviceId,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        _buildUrl(baseUrl, AppConfig.appSubscribePath),
        data: {'device_id': deviceId},
        options: Options(headers: {'Authorization': authData}),
      );
      final data = _requireDataMap(response, fallbackMessage: '获取专属订阅失败');
      final url = data['subscribe_url']?.toString();
      return (url == null || url.isEmpty) ? null : url;
    } catch (_) {
      return null;
    }
  }

  /// 心跳：返回面板最新下发的间隔；失败不抛出，交给调用方决定是否登出。
  Future<V2BoardHeartbeatResult> heartbeat(
    String baseUrl,
    String authData, {
    required String? deviceId,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        _buildUrl(baseUrl, AppConfig.heartbeatPath),
        data: {'device_id': deviceId},
        options: Options(headers: {'Authorization': authData}),
      );
      if (response.statusCode != 200) {
        return V2BoardHeartbeatResult(
          ok: false,
          statusCode: response.statusCode,
          message: _rawMessage(response.data),
        );
      }
      final body = response.data;
      if (body is Map && body['data'] is Map) {
        final data = body['data'] as Map;
        final interval = data['heartbeat_interval'];
        // H-08：面板可以在心跳里下发接入域名与域名池（与设备注册接口一致），
        // 旧版面板不下发时保持现有域名配置。
        final active = data['active']?.toString();
        final pool = (data['domain_pool'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[];
        return V2BoardHeartbeatResult(
          ok: true,
          intervalSeconds: interval is int && interval > 0 ? interval : null,
          statusCode: response.statusCode,
          active: (active == null || active.isEmpty) ? null : active,
          domainPool: pool,
          message: _rawMessage(body) ?? _rawMessage(data),
        );
      }
      return V2BoardHeartbeatResult(
        ok: true,
        statusCode: response.statusCode,
        message: _rawMessage(body),
      );
    } catch (_) {
      return const V2BoardHeartbeatResult(ok: false);
    }
  }

  /// 只取响应里的 `message`/`msg`，没有就返回 null（区别于带 fallback 的
  /// `_extractErrorMessage`）。
  String? _rawMessage(dynamic data) {
    if (data is Map) {
      final message = data['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      final msg = data['msg']?.toString();
      if (msg != null && msg.isNotEmpty) {
        return msg;
      }
    }
    return null;
  }

  /// 上报被墙域名。注意必须带 device_id（参考实现漏传直接 400）。
  Future<V2BoardDomainReportResult?> reportDomain(
    String baseUrl,
    String authData, {
    required String deviceId,
    required String blockedDomain,
  }) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, AppConfig.reportDomainPath),
      data: {'blocked_domain': blockedDomain, 'device_id': deviceId},
      options: Options(headers: {'Authorization': authData}),
    );
    final data = _requireDataMap(response, fallbackMessage: '域名上报失败');
    final active = data['active']?.toString();
    final pool = (data['domain_pool'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    return V2BoardDomainReportResult(active: active, domainPool: pool);
  }

  /// 套餐列表（商城页）。
  Future<List<Map<String, dynamic>>> fetchPlans(
    String baseUrl,
    String authData,
  ) async {
    final body = await _getJson(baseUrl, '/api/v1/user/plan/fetch', authData);
    return _asMapList(body);
  }

  /// 公告列表。
  Future<List<Map<String, dynamic>>> fetchNotices(
    String baseUrl,
    String authData,
  ) async {
    final body = await _getJson(baseUrl, '/api/v1/user/notice/fetch', authData);
    return _asMapList(body);
  }

  /// 工单列表。
  Future<List<Map<String, dynamic>>> fetchTickets(
    String baseUrl,
    String authData,
  ) async {
    final body = await _getJson(baseUrl, '/api/v1/user/ticket/fetch', authData);
    return _asMapList(body);
  }

  /// 工单详情（含消息列表）。
  Future<Map<String, dynamic>?> fetchTicketDetail(
    String baseUrl,
    String authData,
    int ticketId,
  ) async {
    final response = await _dio.get<dynamic>(
      _buildUrl(baseUrl, '/api/v1/user/ticket/fetch'),
      queryParameters: {'id': ticketId},
      options: Options(headers: {'Authorization': authData}),
    );
    final data = response.data;
    if (response.statusCode == 200 && data is Map && data['data'] is Map) {
      return Map<String, dynamic>.from(data['data'] as Map);
    }
    return null;
  }

  /// 新建工单。
  Future<void> createTicket(
    String baseUrl,
    String authData, {
    required String subject,
    required int level,
    required String message,
  }) async {
    await _postExpectTrue(
      baseUrl,
      '/api/v1/user/ticket/save',
      authData,
      data: {'subject': subject, 'level': level, 'message': message},
      fallbackMessage: '提交工单失败',
    );
  }

  /// 回复工单。
  Future<void> replyTicket(
    String baseUrl,
    String authData, {
    required int id,
    required String message,
  }) async {
    await _postExpectTrue(
      baseUrl,
      '/api/v1/user/ticket/reply',
      authData,
      data: {'id': id, 'message': message},
      fallbackMessage: '回复工单失败',
    );
  }

  /// 关闭工单。
  Future<void> closeTicket(
    String baseUrl,
    String authData,
    int id,
  ) async {
    await _postExpectTrue(
      baseUrl,
      '/api/v1/user/ticket/close',
      authData,
      data: {'id': id},
      fallbackMessage: '关闭工单失败',
    );
  }

  /// 创建订单（先取消该账号所有未支付订单，避免重复下单被面板拒绝）。
  Future<String> createOrder(
    String baseUrl,
    String authData, {
    required int planId,
    required String period,
  }) async {
    try {
      final orders = await fetchOrders(baseUrl, authData);
      for (final order in orders) {
        final status = order['status'];
        final tradeNo = order['trade_no']?.toString();
        if (status == 0 && tradeNo != null && tradeNo.isNotEmpty) {
          try {
            await cancelOrder(baseUrl, authData, tradeNo);
          } catch (_) {}
        }
      }
    } catch (_) {}

    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, '/api/v1/user/order/save'),
      data: {'plan_id': planId, 'period': period},
      options: Options(headers: {'Authorization': authData}),
    );
    final body = response.data;
    if (body is Map) {
      final data = body['data'];
      if (data is String && data.isNotEmpty) {
        return data;
      }
      if (data is Map && data['trade_no'] != null) {
        return data['trade_no'].toString();
      }
    }
    throw V2BoardException(
      _extractErrorMessage(body, '下单失败'),
      statusCode: response.statusCode,
    );
  }

  /// 订单列表。
  Future<List<Map<String, dynamic>>> fetchOrders(
    String baseUrl,
    String authData,
  ) async {
    final body = await _getJson(baseUrl, '/api/v1/user/order/fetch', authData);
    return _asMapList(body);
  }

  /// 取消未支付订单。
  Future<void> cancelOrder(
    String baseUrl,
    String authData,
    String tradeNo,
  ) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, '/api/v1/user/order/cancel'),
      data: {'trade_no': tradeNo},
      options: Options(headers: {'Authorization': authData}),
    );
    if (response.statusCode != 200) {
      throw V2BoardException(
        _extractErrorMessage(response.data, '取消订单失败'),
        statusCode: response.statusCode,
      );
    }
  }

  /// 可用支付方式。
  Future<List<Map<String, dynamic>>> getPaymentMethods(
    String baseUrl,
    String authData,
  ) async {
    final body = await _getJson(
      baseUrl,
      '/api/v1/user/order/getPaymentMethod',
      authData,
    );
    return _asMapList(body);
  }

  /// 用户订阅信息（流量/到期/套餐）。
  Future<Map<String, dynamic>?> getUserInfo(
    String baseUrl,
    String authData,
  ) async {
    try {
      final response = await _dio.get<dynamic>(
        _buildUrl(baseUrl, '/api/v1/user/getSubscribe'),
        options: Options(headers: {'Authorization': authData}),
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['data'] is Map) {
        return Map<String, dynamic>.from(data['data'] as Map);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 结算，返回面板生成的支付信息（type: -1 表示直接开通成功）。
  Future<Map<String, dynamic>> checkout(
    String baseUrl,
    String authData, {
    required String tradeNo,
    required int method,
  }) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, '/api/v1/user/order/checkout'),
      data: {'trade_no': tradeNo, 'method': method},
      options: Options(headers: {'Authorization': authData}),
    );
    final body = response.data;
    if (body is Map) {
      final data = body['data'];
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return Map<String, dynamic>.from(body);
    }
    throw V2BoardException(
      _extractErrorMessage(body, '获取支付信息失败'),
      statusCode: response.statusCode,
    );
  }

  /// GET 并解开 v2board 的 `{data: ...}` 外壳（非 200 时抛 V2BoardException）。
  Future<dynamic> _getJson(
    String baseUrl,
    String path,
    String authData,
  ) async {
    final response = await _dio.get<dynamic>(
      _buildUrl(baseUrl, path),
      options: Options(headers: {'Authorization': authData}),
    );
    if (response.statusCode != 200) {
      throw V2BoardException(
        _extractErrorMessage(response.data, '请求失败'),
        statusCode: response.statusCode,
      );
    }
    final body = response.data;
    if (body is Map) {
      return body['data'];
    }
    return null;
  }

  /// POST 且面板返回 `data == true` 视为成功。
  Future<void> _postExpectTrue(
    String baseUrl,
    String path,
    String authData, {
    required Map<String, dynamic> data,
    required String fallbackMessage,
  }) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, path),
      data: data,
      options: Options(headers: {'Authorization': authData}),
    );
    final body = response.data;
    if (response.statusCode == 200 && body is Map && body['data'] == true) {
      return;
    }
    throw V2BoardException(
      _extractErrorMessage(body, fallbackMessage),
      statusCode: response.statusCode,
    );
  }

  List<Map<String, dynamic>> _asMapList(dynamic data) {
    if (data is List) {
      return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// 生成 TOTP + 时效 + 签名的专属订阅链接（基于面板下发的 subscribe_url）。
  String buildSignedSubscribeUrl({
    required String subscribeUrl,
    required String deviceId,
    required String totpSecret,
  }) {
    return Totp.buildSignedSubscribeUrl(
      subscribeUrl: subscribeUrl,
      deviceId: deviceId,
      totpSecret: totpSecret,
    );
  }

  /// 普通订阅链接：原样保留面板下发的地址，只补 `flag=meta`。
  String buildPlainSubscribeUrl(String subscribeUrl) {
    final uri = Uri.parse(subscribeUrl.trim());
    final query = Map<String, String>.from(uri.queryParameters);
    query.putIfAbsent('flag', () => 'meta');
    return uri.replace(queryParameters: query).toString();
  }

  Map<String, dynamic> _requireDataMap(
    Response<dynamic> response, {
    required String fallbackMessage,
  }) {
    final data = response.data;
    if (response.statusCode != 200) {
      throw V2BoardException(
        _extractErrorMessage(data, fallbackMessage),
        statusCode: response.statusCode,
      );
    }
    if (data is! Map) {
      throw V2BoardException(fallbackMessage);
    }
    final realData = data['data'];
    if (realData is! Map) {
      throw V2BoardException(
        _extractErrorMessage(data, fallbackMessage),
        statusCode: response.statusCode,
      );
    }
    return Map<String, dynamic>.from(realData);
  }

  String _extractErrorMessage(dynamic data, String fallbackMessage) {
    if (data is Map) {
      final message = data['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      final msg = data['msg']?.toString();
      if (msg != null && msg.isNotEmpty) {
        return msg;
      }
    }
    return fallbackMessage;
  }
}

final v2BoardClient = V2BoardClient.instance;
