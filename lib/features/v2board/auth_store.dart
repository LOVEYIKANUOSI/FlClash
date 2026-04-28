import 'package:shared_preferences/shared_preferences.dart';

class AuthStore {
  static const _panelUrlKey = 'auth_panel_url';
  static const _emailKey = 'auth_email';
  static const _authDataKey = 'auth_data';
  static const _tokenKey = 'auth_token';
  static const _subscribeUrlKey = 'auth_subscribe_url';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String? get panelUrl => _prefs?.getString(_panelUrlKey);
  String? get email => _prefs?.getString(_emailKey);
  String? get authData => _prefs?.getString(_authDataKey);
  String? get token => _prefs?.getString(_tokenKey);
  String? get subscribeUrl => _prefs?.getString(_subscribeUrlKey);

  bool get hasSession {
    final a = authData;
    final p = panelUrl;
    return a != null && a.isNotEmpty && p != null && p.isNotEmpty;
  }

  Future<void> save({
    required String panelUrl,
    required String email,
    required String authData,
    required String token,
    required String subscribeUrl,
  }) async {
    await _prefs?.setString(_panelUrlKey, panelUrl);
    await _prefs?.setString(_emailKey, email);
    await _prefs?.setString(_authDataKey, authData);
    await _prefs?.setString(_tokenKey, token);
    await _prefs?.setString(_subscribeUrlKey, subscribeUrl);
  }

  Future<void> clear() async {
    await _prefs?.remove(_panelUrlKey);
    await _prefs?.remove(_emailKey);
    await _prefs?.remove(_authDataKey);
    await _prefs?.remove(_tokenKey);
    await _prefs?.remove(_subscribeUrlKey);
  }
}
