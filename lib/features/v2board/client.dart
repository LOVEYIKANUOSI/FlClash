import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';

import 'app_config.dart';
import 'totp.dart';

/// V2Board 接口调用失败时抛出，message 直接展示给用户。
class V2BoardException implements Exception {
  final String message;
  final int? statusCode;

  const V2BoardException(this.message, {this.statusCode});

  /// 认证失效（需要重新登录）。
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

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

  const V2BoardHeartbeatResult({
    required this.ok,
    this.intervalSeconds,
    this.statusCode,
  });

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;
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
/// - 专属订阅：POST /api/v1/user/appSubscribe → data.subscribe_url
/// - 心跳：POST /api/v1/user/heartbeat → data.heartbeat_interval
/// - 域名上报：POST /api/v1/user/reportDomain → data.active/domain_pool
class V2BoardClient {
  V2BoardClient._();

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
  );

  String _buildUrl(String baseUrl, String path) {
    return '${AppConfig.normalizeUrl(baseUrl)}$path';
  }

  /// 登录，返回 auth_data（后续请求的 Authorization 头）和 token。
  Future<V2BoardLoginResult> login({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, AppConfig.loginPath),
      data: {'email': email.trim(), 'password': password},
    );
    final data = _requireDataMap(response, fallbackMessage: '登录失败');
    final authData = data['auth_data']?.toString();
    final token = data['token']?.toString();
    if (authData == null || authData.isEmpty) {
      throw const V2BoardException('登录失败：面板未返回 auth_data');
    }
    return V2BoardLoginResult(authData: authData, token: token ?? '');
  }

  /// 校验当前登录态是否仍然有效。
  Future<bool> checkLogin(String baseUrl, String authData) async {
    try {
      final response = await _dio.get<dynamic>(
        _buildUrl(baseUrl, AppConfig.checkLoginPath),
        options: Options(headers: {'Authorization': authData}),
      );
      final data = _requireDataMap(response, fallbackMessage: '检查登录状态失败');
      return data['is_login'] == true;
    } catch (_) {
      return false;
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
    if (data['active'] == false) {
      throw const V2BoardException('设备已被限制，请联系客服');
    }
    return data;
  }

  /// 面板下发的设备专属订阅链接（普通订阅的进阶版）。
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
        );
      }
      final body = response.data;
      if (body is Map && body['data'] is Map) {
        final interval = (body['data'] as Map)['heartbeat_interval'];
        return V2BoardHeartbeatResult(
          ok: true,
          intervalSeconds: interval is int && interval > 0 ? interval : null,
          statusCode: response.statusCode,
        );
      }
      return V2BoardHeartbeatResult(
        ok: true,
        statusCode: response.statusCode,
      );
    } catch (_) {
      return const V2BoardHeartbeatResult(ok: false);
    }
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
