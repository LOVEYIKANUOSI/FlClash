import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/v2board_profile.dart';

import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';

import 'app_config.dart';
import 'auth_store.dart';
import 'client.dart';
import 'domain_probe_service.dart';
import 'heartbeat_service.dart';
import 'security_report_service.dart';

/// Dawn 客户端登录态 + 设备/订阅/心跳/域名池的唯一状态源。
///
/// 用 ChangeNotifier 而不是 Riverpod codegen，避免为了移植再跑一次 build_runner；
/// UI 侧用 [AnimatedBuilder] 监听即可。
class V2BoardState extends ChangeNotifier {
  V2BoardState._();

  static final V2BoardState instance = V2BoardState._();

  final AuthStore _store = AuthStore();

  bool _initialized = false;
  bool _busy = false;
  bool _loginCompleted = false;
  String? _lastError;
  String? _notice;
  DateTime? _lastHeartbeatAt;
  bool _lastHeartbeatOk = false;
  bool _initStarted = false;

  bool get initialized => _initialized;
  bool get busy => _busy;
  bool get hasSession => _store.hasSession;
  bool get loginCompleted => _loginCompleted;
  String? get lastError => _lastError;
  String? get notice => _notice;
  bool get lastHeartbeatOk => _lastHeartbeatOk;
  DateTime? get lastHeartbeatAt => _lastHeartbeatAt;

  String get email => _store.email ?? '';
  String get panelUrl => _store.panelUrl;
  String get apiBaseUrl => _store.apiBaseUrl;
  String get deviceId => _store.deviceId ?? '';
  String get activeDomain => _store.activeDomain;
  List<String> get domainPool => _store.domainPool;
  String? get subscribeUrl => _store.subscribeUrl;
  int get heartbeatIntervalSeconds => _store.heartbeatIntervalSeconds;
  DomainSwitchOutcome? get lastProbeOutcome =>
      DomainProbeService.instance.lastOutcome;

  /// App 启动时调用：恢复会话 → 校验登录态 → 重建订阅/服务。
  Future<void> init() async {
    if (_initStarted) {
      return;
    }
    _initStarted = true;
    await _store.init();
    _refreshFromStore();
    notifyListeners();

    if (!_store.hasSession) {
      _initialized = true;
      notifyListeners();
      return;
    }

    await _waitUntilAttached();
    final authData = _store.authData;
    if (authData == null || authData.isEmpty) {
      await _handleSessionExpired('登录状态已失效，请重新登录');
      return;
    }

    final stillValid =
        await v2BoardClient.checkLogin(_store.apiBaseUrl, authData);
    if (!stillValid) {
      await _handleSessionExpired('登录状态已失效，请重新登录');
      return;
    }

    // 已有 Dawn 订阅就用旧的（离线配置本身可用），避免每次启动重复导入/丢失节点选择
    await _afterLogin(importProfile: !hasDawnProfile());
    _initialized = true;
    notifyListeners();
  }

  /// 登录：账号密码 → 设备注册 → 专属订阅 → 导入订阅 → 启动心跳/域名探测。
  Future<void> login({
    required String email,
    required String password,
    required String panelUrl,
  }) async {
    if (_busy) {
      return;
    }
    _setBusy(true);
    _lastError = null;
    _notice = null;
    try {
      await _store.init();
      final normalizedPanelUrl = AppConfig.normalizeUrl(panelUrl);
      if (normalizedPanelUrl.isEmpty) {
        throw const V2BoardException('请输入面板地址');
      }

      final result = await v2BoardClient.login(
        baseUrl: normalizedPanelUrl,
        email: email,
        password: password,
      );
      await _store.save(
        panelUrl: normalizedPanelUrl,
        email: email.trim(),
        authData: result.authData,
        token: result.token,
      );

      // 注册设备（带回环境画像），拿 device_id / totp_secret / 域名池
      Map<String, dynamic>? device;
      try {
        device = await SecurityReportService.instance.registerWithProfile();
      } catch (e) {
        commonPrint.log('[V2Board] 设备注册失败，回退普通订阅: $e');
      }

      // 优先用专属订阅（TOTP 签名），没有设备时退回普通订阅
      _store.setSubscribeUrl(await _resolveSubscribeUrl());

      await _afterLogin(importProfile: true, replaceExisting: true);
      _loginCompleted = true;
      _notice = device == null ? '登录成功（设备注册失败，已回退普通订阅）' : '登录成功';
    } on V2BoardException catch (e) {
      _lastError = e.message;
      // 登录链路失败时清掉已落盘的半成品会话：否则 authData 已存在，
      // 门禁会误以为已登录直接放行，但心跳/探测/订阅都没启动（表现为「尚未上报」）。
      await _store.clearSession();
      _refreshFromStore();
    } catch (e) {
      _lastError = '登录失败：$e';
      await _store.clearSession();
      _refreshFromStore();
    } finally {
      _setBusy(false);
    }
  }

  Future<String> _resolveSubscribeUrl() async {
    final authData = _store.authData;
    if (authData == null || authData.isEmpty) {
      throw const V2BoardException('登录状态已失效，请重新登录');
    }
    // 订阅地址必须用面板下发的 subscribe_url：生产 subscribe_path 已随机化，
    // 自己拼 /api/v1/client/subscribe 会 404（签名 payload 才用字面量）。
    final subscribeInfo = await v2BoardClient.getSubscribe(
      _store.apiBaseUrl,
      authData,
    );
    final subscribeUrl = subscribeInfo?['subscribe_url']?.toString() ?? '';
    if (subscribeUrl.isEmpty) {
      throw const V2BoardException('面板未返回订阅链接');
    }
    // 面板的 subscribe_url 是在「订阅域名池」里随机挑一个下发的（配置见
    // subscribe_url 逗号分割）。这些域名可能已失效（实测 cdn-bing 返回 504），
    // 所以先确认它的 host 可用；不可用就保留 path/query（随机 path + token），
    // 换成刚验证过可用的 API 域名——签名只认 path，不认 host。
    final usableSubscribeUrl = await _ensureSubscribeHost(subscribeUrl);
    final deviceId = _store.deviceId;
    final totpSecret = _store.totpSecret;
    if (deviceId != null &&
        deviceId.isNotEmpty &&
        totpSecret != null &&
        totpSecret.isNotEmpty) {
      return v2BoardClient.buildSignedSubscribeUrl(
        subscribeUrl: usableSubscribeUrl,
        deviceId: deviceId,
        totpSecret: totpSecret,
      );
    }
    return v2BoardClient.buildPlainSubscribeUrl(usableSubscribeUrl);
  }

  /// 确认面板下发的订阅 host 真的能用（占位符 / Cloudflare 5xx 都不算）。
  /// 不可用时把同一个 path/query 换到 apiBaseUrl 上返回。
  Future<String> _ensureSubscribeHost(String subscribeUrl) async {
    final uri = Uri.tryParse(subscribeUrl);
    if (uri == null || uri.host.isEmpty) {
      return subscribeUrl;
    }
    if (!AppConfig.isUsableDomain(uri.host)) {
      commonPrint.log('[V2Board] 订阅域名是占位符，改用 API 域名: ${uri.host}');
      return _subscribeUrlOnApiHost(subscribeUrl) ?? subscribeUrl;
    }
    final apiUri = Uri.tryParse(_store.apiBaseUrl);
    if (apiUri != null && apiUri.host == uri.host) {
      return subscribeUrl;
    }
    try {
      final result = await DomainProbeService.instance.probe(uri.host);
      if (result.healthy) {
        return subscribeUrl;
      }
      commonPrint.log(
        '[V2Board] 订阅域名不可用(状态=${result.statusCode})，改用 API 域名: ${uri.host}',
      );
      return _subscribeUrlOnApiHost(subscribeUrl) ?? subscribeUrl;
    } catch (_) {
      return _subscribeUrlOnApiHost(subscribeUrl) ?? subscribeUrl;
    }
  }

  /// 登录成功后的统一收尾：生成订阅、启动心跳/探测、导入 profile。
  Future<void> _afterLogin({
    required bool importProfile,
    bool replaceExisting = false,
  }) async {
    final url = _store.subscribeUrl ?? await _resolveSubscribeUrl();
    _store.setSubscribeUrl(url);

    HeartbeatService.instance.onResult = _onHeartbeatResult;
    HeartbeatService.instance.start(
      interval: Duration(seconds: _store.heartbeatIntervalSeconds),
    );
    DomainProbeService.instance.onOutcome = (_) => notifyListeners();
    DomainProbeService.instance.start();

    _refreshFromStore();
    notifyListeners();

    if (importProfile) {
      await _importProfile(url, replaceExisting: replaceExisting);
    }
  }

  Future<void> _importProfile(
    String url, {
    bool replaceExisting = false,
  }) async {
    try {
      await addDawnProfileFromLink(url, replace: replaceExisting);
    } catch (e) {
      final fallbackUrl = _subscribeUrlOnApiHost(url);
      if (fallbackUrl != null) {
        commonPrint.log('[V2Board] 订阅域名不可用，改用当前 API 域名重试: $e');
        try {
          await addDawnProfileFromLink(fallbackUrl, replace: replaceExisting);
          return;
        } catch (e2) {
          _lastError = '订阅已获取，但导入失败：$e2';
          notifyListeners();
          return;
        }
      }
      commonPrint.log('[V2Board] 导入订阅失败: $e');
      _lastError = '订阅已获取，但导入失败：$e';
      notifyListeners();
    }
  }

  /// 面板的 `subscribe_url` 是配置里的域名池随机挑一个下发的，可能有域名已失效。
  /// 失败时保留原 path/query（含随机化的 subscribe_path 和 token），换成当前可用的
  /// API 域名重试；签名只跟 path 有关，换域名不影响验签。
  String? _subscribeUrlOnApiHost(String url) {
    final uri = Uri.tryParse(url);
    final api = Uri.tryParse(_store.apiBaseUrl);
    if (uri == null || api == null) {
      return null;
    }
    if (uri.host.isEmpty || api.host.isEmpty || uri.host == api.host) {
      return null;
    }
    final authority = api.hasPort ? '${api.host}:${api.port}' : api.host;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return '${api.scheme}://$authority${uri.path}$query';
  }

  void _onHeartbeatResult(V2BoardHeartbeatResult result) {
    _lastHeartbeatAt = DateTime.now();
    _lastHeartbeatOk = result.ok;
    notifyListeners();
    if (result.isUnauthorized) {
      unawaited(_handleSessionExpired('登录状态已失效，请重新登录'));
    }
  }

  /// 重新签发专属订阅并重新导入（TOTP 只活 2 分钟，切节点/重连前刷新）。
  Future<void> refreshSubscribe() async {
    if (!_store.hasSession) {
      return;
    }
    _setBusy(true);
    try {
      final url = await _resolveSubscribeUrl();
      _store.setSubscribeUrl(url);
      await _importProfile(url, replaceExisting: true);
      _notice = '订阅已刷新';
    } catch (e) {
      _lastError = '刷新订阅失败：$e';
    } finally {
      _setBusy(false);
    }
  }

  /// 立即重新注册设备（刷新设备信息/域名池）。
  Future<void> refreshDevice() async {
    if (!_store.hasSession) {
      return;
    }
    _setBusy(true);
    try {
      final device = await SecurityReportService.instance.registerWithProfile();
      if (device == null) {
        _lastError = '设备注册失败，请稍后重试';
      } else {
        _notice = '设备信息已刷新';
      }
      _refreshFromStore();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> heartbeatNow() async {
    await HeartbeatService.instance.beat();
    _refreshFromStore();
  }

  Future<void> probeNow() async {
    _setBusy(true);
    try {
      final outcome = await DomainProbeService.instance.checkAndSwitch();
      _notice = outcome.switched
          ? '已切换域名：${outcome.newActive}'
          : (outcome.error ?? '当前域名可用');
      _refreshFromStore();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> logout() async {
    await _handleSessionExpired(null);
  }

  Future<void> _handleSessionExpired(String? message) async {
    HeartbeatService.instance.stop();
    DomainProbeService.instance.stop();
    HeartbeatService.instance.onResult = null;
    DomainProbeService.instance.onOutcome = null;
    await _store.clear();
    _refreshFromStore();
    _loginCompleted = false;
    if (message != null) {
      _lastError = message;
    }
    _initialized = true;
    // 会话失效时退出到根路由，否则用户可能停在 tools 等子页看不到登录页
    final navigator = globalState.navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    notifyListeners();
  }

  void clearNotice() {
    if (_notice == null && _lastError == null) {
      return;
    }
    _notice = null;
    _lastError = null;
    notifyListeners();
  }

  void _refreshFromStore() {
    notifyListeners();
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  Future<void> _waitUntilAttached() async {
    for (var i = 0; i < 150; i++) {
      if (globalState.isAttach == true) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

final v2BoardState = V2BoardState.instance;
