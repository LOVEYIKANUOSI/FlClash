import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/credential_cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 自动登录保存的账号密码（只在内存里短暂出现，落盘走系统加密存储）。
class AutoLoginCredential {
  const AutoLoginCredential({required this.email, required this.password});

  final String email;
  final String password;
}

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

  /// 自动登录：开启时间戳（毫秒）与加密后的账号密码都存 shared_preferences，
  /// 但密码字段是 AES-256-GCM 密文（密钥由本机环境指纹派生、不落盘），
  /// 明文不会出现。加密实现见 [CredentialCipher]。
  static const _autoLoginAtKey = 'v2b_auto_login_at';
  static const _autoCredentialKey = 'v2b_auto_credential';

  /// 自动登录有效期：365 天。过期后必须重新用账号密码登录。
  static const autoLoginValidity = Duration(days: 365);

  SharedPreferences? _prefs;

  static String? _subscribeUrl;

  /// 读取一个「落盘密文」字段。
  ///
  /// 旧版本存的是明文（没有 `enc:v1:` 前缀）：本次先按明文返回保证可用，
  /// 同时异步把它重写成密文，下次启动就只剩密文了。
  String? _readSecret(String key) {
    final prefs = _prefs;
    if (prefs == null) {
      return null;
    }
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      return raw;
    }
    if (!CredentialCipher.isEncryptedField(raw)) {
      final encrypted = CredentialCipher.encryptField(raw);
      if (encrypted != raw) {
        unawaited(prefs.setString(key, encrypted));
      }
      return raw;
    }
    return CredentialCipher.decryptField(raw);
  }

  /// 写入一个「落盘密文」字段。
  Future<void> _writeSecret(String key, String value) async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(key, CredentialCipher.encryptField(value));
  }

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 用户填写的面板地址；没填过就用默认生产入口。
  String get panelUrl => _prefs?.getString(_panelUrlKey) ?? AppConfig.defaultPanelUrl;

  String? get email => _prefs?.getString(_emailKey);

  /// 面板 JWT / 订阅 token / 设备 ID / TOTP 密钥都按「落盘密文」存放：
  /// 拷走 shared_preferences.json 也拿不到可用凭证（见 [CredentialCipher]）。
  String? get authData => _readSecret(_authDataKey);
  String? get token => _readSecret(_tokenKey);
  String? get subscribeUrl => _subscribeUrl;

  /// 面板下发的设备 ID。
  String? get deviceId => _readSecret(_deviceIdKey);

  /// 设备专属 TOTP secret。
  String? get totpSecret => _readSecret(_totpSecretKey);

  /// 面板下发的心跳间隔（秒）。
  int get heartbeatIntervalSeconds =>
      _prefs?.getInt(_heartbeatIntervalKey) ??
      AppConfig.defaultHeartbeatInterval.inSeconds;

  /// 当前使用的对接域名（未下发/下发的是占位符时用面板地址对应的 host）。
  String get activeDomain {
    final saved = _prefs?.getString(_activeDomainKey);
    if (saved != null && AppConfig.isUsableDomain(saved)) {
      return saved;
    }
    return Uri.tryParse(panelUrl)?.host ?? '';
  }

  /// 面板 API 实际使用的 baseUrl：
  /// 面板下发过可用的 active 域名就用它（带 scheme），否则用用户填写的面板地址。
  String get apiBaseUrl {
    final saved = _prefs?.getString(_activeDomainKey);
    if (saved != null && AppConfig.isUsableDomain(saved)) {
      return AppConfig.normalizeDomain(saved);
    }
    return AppConfig.normalizeUrl(panelUrl);
  }

  /// 客户端专属域名池（过滤掉面板没配置时下发的占位符）。
  List<String> get domainPool =>
      (_prefs?.getStringList(_domainPoolKey) ?? const [])
          .where(AppConfig.isUsableDomain)
          .toList();

  /// 是否已开启自动登录且仍在 1 年有效期内。
  bool get autoLoginEnabled {
    final at = _prefs?.getInt(_autoLoginAtKey);
    if (at == null || at <= 0) {
      return false;
    }
    final elapsed = DateTime.now().millisecondsSinceEpoch - at;
    return elapsed >= 0 && elapsed < autoLoginValidity.inMilliseconds;
  }

  /// 自动登录到期时间；没开启或已过期返回 null。
  DateTime? get autoLoginExpiresAt {
    final at = _prefs?.getInt(_autoLoginAtKey);
    if (at == null || at <= 0) {
      return null;
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      at + autoLoginValidity.inMilliseconds,
    );
    return expiresAt.isAfter(DateTime.now()) ? expiresAt : null;
  }

  /// 保存自动登录凭据：密码加密后落盘，只记录开启时间。
  ///
  /// 返回是否真的保存成功（加密失败返回 false，界面上要能看出来）。
  Future<bool> saveAutoLogin({
    required String email,
    required String password,
  }) async {
    final prefs = _prefs;
    if (prefs == null) {
      return false;
    }
    final plain = jsonEncode({'email': email, 'password': password});
    final encrypted = CredentialCipher.encrypt(plain);
    if (encrypted == null || encrypted.isEmpty) {
      debugPrint('[AutoLogin] 凭据加密失败，未保存');
      return false;
    }
    await prefs.setString(_autoCredentialKey, encrypted);
    await prefs.setInt(_autoLoginAtKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_emailKey, email);
    return true;
  }

  /// 读取自动登录凭据；未开启、已过期或解密失败都返回 null。
  Future<AutoLoginCredential?> readAutoLogin() async {
    final prefs = _prefs;
    if (prefs == null || !autoLoginEnabled) {
      return null;
    }
    final encrypted = prefs.getString(_autoCredentialKey);
    if (encrypted == null || encrypted.isEmpty) {
      return null;
    }
    final plain = CredentialCipher.decrypt(encrypted);
    if (plain == null || plain.isEmpty) {
      debugPrint('[AutoLogin] 凭据解密失败（换了机器/用户或数据损坏）');
      return null;
    }
    try {
      final map = jsonDecode(plain);
      if (map is! Map) {
        return null;
      }
      final email = (map['email'] ?? '').toString();
      final password = (map['password'] ?? '').toString();
      if (email.isEmpty || password.isEmpty) {
        return null;
      }
      return AutoLoginCredential(email: email, password: password);
    } catch (e) {
      debugPrint('[AutoLogin] 凭据解析失败: $e');
      return null;
    }
  }

  /// 关闭自动登录并删除已保存的密码。
  Future<void> clearAutoLogin() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.remove(_autoCredentialKey);
    await prefs.remove(_autoLoginAtKey);
  }

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
    await _writeSecret(_authDataKey, authData);
    await _writeSecret(_tokenKey, token);
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
    await _writeSecret(_deviceIdKey, deviceId);
    await _writeSecret(_totpSecretKey, totpSecret);
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
    // 面板域名池没配置时下发的是占位符，不能落盘当 API 域名用。
    final usablePool =
        domainPool.where(AppConfig.isUsableDomain).toList(growable: false);
    final String usableActive;
    if (AppConfig.isUsableDomain(activeDomain)) {
      usableActive = activeDomain.trim();
    } else if (usablePool.isNotEmpty) {
      usableActive = usablePool.first;
    } else {
      usableActive = '';
    }
    if (usableActive.isEmpty) {
      await prefs.remove(_activeDomainKey);
    } else {
      await prefs.setString(_activeDomainKey, usableActive);
    }
    if (usablePool.isEmpty) {
      await prefs.remove(_domainPoolKey);
    } else {
      await prefs.setStringList(_domainPoolKey, usablePool);
    }
  }

  /// 只清会话与设备信息，保留面板地址/邮箱（登录页可以回填）。
  Future<void> clearSession() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.remove(_authDataKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_deviceIdKey);
    await prefs.remove(_totpSecretKey);
    await prefs.remove(_activeDomainKey);
    await prefs.remove(_domainPoolKey);
    await prefs.remove(_heartbeatIntervalKey);
    _subscribeUrl = null;
  }

  Future<void> clear() async {
    await clearSession();
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.remove(_panelUrlKey);
    await prefs.remove(_emailKey);
  }
}
