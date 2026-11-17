import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// V2Board 登录凭证 / 设备信息 / 域名池的持久化存储。
///
/// 订阅链接含 TOTP 动态参数，只在内存里保留，进程退出即失效；
/// 下次启动用 deviceId + totpSecret 重新签发。
class AuthStore {
  static const _panelUrlKey = 'v2b_panel_url';
  static const _emailKey = 'v2b_email';
  static const _authDataKey = 'v2b_auth_data';
  static const _tokenKey = 'v2b_token';

  static const _deviceIdKey = 'v2b_device_id';
  static const _totpSecretKey = 'v2b_totp_secret';
  static const _activeDomainKey = 'v2b_active_domain';
  static const _domainPoolKey = 'v2b_domain_pool';
  static const _heartbeatIntervalKey = 'v2b_heartbeat_interval';

  SharedPreferences? _prefs;

  static String? _subscribeUrl;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 用户填写的面板地址；没填过就用默认生产入口。
  String get panelUrl => _prefs?.getString(_panelUrlKey) ?? AppConfig.defaultPanelUrl;

  String? get email => _prefs?.getString(_emailKey);
  String? get authData => _prefs?.getString(_authDataKey);
  String? get token => _prefs?.getString(_tokenKey);
  String? get subscribeUrl => _subscribeUrl;

  /// 面板下发的设备 ID。
  String? get deviceId => _prefs?.getString(_deviceIdKey);

  /// 设备专属 TOTP secret。
  String? get totpSecret => _prefs?.getString(_totpSecretKey);

  /// 面板下发的心跳间隔（秒）。
  int get heartbeatIntervalSeconds =>
      _prefs?.getInt(_heartbeatIntervalKey) ??
      AppConfig.defaultHeartbeatInterval.inSeconds;

  /// 当前使用的对接域名（未下发时用面板地址对应的 host）。
  String get activeDomain {
    final saved = _prefs?.getString(_activeDomainKey);
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    return Uri.tryParse(panelUrl)?.host ?? '';
  }

  /// 面板 API 实际使用的 baseUrl：
  /// 面板下发过 active 域名就用它（带 scheme），否则用用户填写的面板地址。
  String get apiBaseUrl {
    final saved = _prefs?.getString(_activeDomainKey);
    if (saved != null && saved.isNotEmpty) {
      return AppConfig.normalizeDomain(saved);
    }
    return AppConfig.normalizeUrl(panelUrl);
  }

  /// 客户端专属域名池。
  List<String> get domainPool =>
      _prefs?.getStringList(_domainPoolKey) ?? const [];

  bool get hasSession {
    final auth = authData;
    return auth != null && auth.isNotEmpty;
  }

  Future<void> save({
    required String panelUrl,
    required String email,
    required String authData,
    required String token,
    String? subscribeUrl,
  }) async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(_panelUrlKey, AppConfig.normalizeUrl(panelUrl));
    await prefs.setString(_emailKey, email);
    await prefs.setString(_authDataKey, authData);
    await prefs.setString(_tokenKey, token);
    _subscribeUrl = subscribeUrl;
  }

  void setSubscribeUrl(String url) {
    _subscribeUrl = url;
  }

  Future<void> saveDevice({
    required String deviceId,
    required String totpSecret,
    int? heartbeatIntervalSeconds,
  }) async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(_deviceIdKey, deviceId);
    await prefs.setString(_totpSecretKey, totpSecret);
    if (heartbeatIntervalSeconds != null && heartbeatIntervalSeconds > 0) {
      await prefs.setInt(_heartbeatIntervalKey, heartbeatIntervalSeconds);
    }
  }

  Future<void> saveDomains({
    required String activeDomain,
    required List<String> domainPool,
  }) async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(_activeDomainKey, activeDomain);
    await prefs.setStringList(_domainPoolKey, domainPool);
  }

  Future<void> clear() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.remove(_panelUrlKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_authDataKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_deviceIdKey);
    await prefs.remove(_totpSecretKey);
    await prefs.remove(_activeDomainKey);
    await prefs.remove(_domainPoolKey);
    await prefs.remove(_heartbeatIntervalKey);
    _subscribeUrl = null;
  }
}
