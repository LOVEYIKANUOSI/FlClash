import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';

class V2BoardCredentials {
  final String baseUrl;
  final String email;
  final String password;

  const V2BoardCredentials({
    required this.baseUrl,
    required this.email,
    required this.password,
  });
}

class V2BoardClient {
  final Dio _dio = Dio(
    BaseOptions(
      headers: {'User-Agent': browserUa, 'Accept': 'application/json'},
      responseType: ResponseType.json,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  // ==== 新增字段（登录门控需要）====
  String? lastAuthData;
  String? lastToken;

  // ==== 新增方法：验证登录态 ====
  Future<bool> checkLogin(String baseUrl, String authData) async {
    try {
      final response = await _dio.get<dynamic>(
        _buildUrl(baseUrl, '/api/v1/user/checkLogin'),
        options: Options(headers: {'Authorization': authData}),
      );
      final data = _requireDataMap(response, fallbackMessage: '检查登录状态失败');
      return data['is_login'] == true;
    } catch (_) {
      return false;
    }
  }

  // ==== 新增方法：获取套餐列表 ====
  Future<List<Map<String, dynamic>>> fetchPlans(
    String baseUrl,
    String authData,
  ) async {
    final response = await _dio.get<dynamic>(
      _buildUrl(baseUrl, '/api/v1/user/plan/fetch'),
      options: Options(headers: {'Authorization': authData}),
    );
    final body = response.data;
    if (body is Map && body['data'] is List) {
      return (body['data'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  // ==== 新增方法：创建订单 ====
  Future<Map<String, dynamic>> createOrder(
    String baseUrl,
    String authData, {
    required int planId,
    required String period,
  }) async {
    final response = await _dio.post<dynamic>(
      _buildUrl(baseUrl, '/api/v1/user/order/save'),
      data: {'plan_id': planId, 'period': period},
      options: Options(headers: {'Authorization': authData}),
    );
    print('[V2Board] createOrder status=${response.statusCode} body=${response.data}');
    return _requireDataMap(response, fallbackMessage: '下单失败');
  }

  String _normalizeBaseUrl(String value) {
    final baseUrl = value.trim();
    if (!baseUrl.isUrl) {
      throw '请输入完整的面板地址，例如 https://panel.example.com';
    }
    return baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
  }

  String _buildUrl(String baseUrl, String path) {
    return '${_normalizeBaseUrl(baseUrl)}$path';
  }

  Map<String, dynamic> _requireDataMap(
    Response<dynamic> response, {
    required String fallbackMessage,
  }) {
    final data = response.data;
    if (response.statusCode != 200) {
      throw _extractErrorMessage(data).takeFirstValid([fallbackMessage]);
    }
    if (data is! Map<String, dynamic>) {
      throw fallbackMessage;
    }
    final realData = data['data'];
    if (realData is! Map<String, dynamic>) {
      throw _extractErrorMessage(data).takeFirstValid([fallbackMessage]);
    }
    return realData;
  }

  String _extractErrorMessage(dynamic data) {
    if (data is Map<String, dynamic>) {
      final message = data['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      final error = data['msg']?.toString();
      if (error != null && error.isNotEmpty) {
        return error;
      }
    }
    return '请求失败';
  }

  Uri _appendFlagMeta(String subscribeUrl) {
    final uri = Uri.parse(subscribeUrl);
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'flag': 'meta'},
    );
  }

  Future<String> loginAndGetSubscribeUrl(V2BoardCredentials credentials) async {
    final loginResponse = await _dio.post<dynamic>(
      _buildUrl(credentials.baseUrl, '/api/v1/passport/auth/login'),
      data: {
        'email': credentials.email.trim(),
        'password': credentials.password,
      },
    );
    print('[V2Board] login status=${loginResponse.statusCode} body=${loginResponse.data}');
    final loginData = _requireDataMap(loginResponse, fallbackMessage: '登录失败');
    final authData = loginData['auth_data']?.toString();
    final token = loginData['token']?.toString();
    if (authData == null || authData.isEmpty) {
      throw '登录失败：未获取到 auth_data';
    }
    // ==== 新增：保存认证数据 ====
    lastAuthData = authData;
    lastToken = token;

    final subscribeResponse = await _dio.get<dynamic>(
      _buildUrl(credentials.baseUrl, '/api/v1/user/getSubscribe'),
      options: Options(headers: {'Authorization': authData}),
    );
    final subscribeData = _requireDataMap(
      subscribeResponse,
      fallbackMessage: '获取订阅地址失败',
    );

    final subscribeUrl = subscribeData['subscribe_url']?.toString();
    if (subscribeUrl != null && subscribeUrl.isNotEmpty) {
      return _appendFlagMeta(subscribeUrl).toString();
    }
    if (token != null && token.isNotEmpty) {
      final fallbackUri = Uri.parse(
        _buildUrl(credentials.baseUrl, '/api/v1/client/subscribe'),
      ).replace(queryParameters: {'token': token, 'flag': 'meta'});
      return fallbackUri.toString();
    }
    throw '获取订阅地址失败';
  }
}

final v2BoardClient = V2BoardClient();
