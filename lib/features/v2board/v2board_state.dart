import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/v2board_profile.dart';
import 'package:fl_clash/features/update/update_dialog.dart';
import 'package:fl_clash/features/update/update_service.dart';
import 'package:fl_clash/providers/providers.dart';
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
  bool _autoLoginRunning = false;
  bool _recoveringSession = false;

  /// 最近一次登录/重登失败是否属于网络或面板不可达（不是账号问题）。
  ///
  /// 面板短时故障时绝不能清会话、删免密凭据或踢回登录页——否则面板抖一下
  /// 全体客户端都会被迫重新登录（2026-11-21 的「一直弹登录失败」就是这个）。
  bool _lastFailureNetwork = false;

  /// 上次因网络失败放弃静默重登的时间，用于退避，避免每 60 秒重登风暴。
  DateTime? _lastNetworkRecoverAt;

  /// Dawn 订阅重签定时器 + 防重入标记。
  Timer? _dawnRefreshTimer;
  bool _refreshingDawnProfile = false;

  bool get initialized => _initialized;
  bool get busy => _busy;
  bool get hasSession => _store.hasSession;
  bool get loginCompleted => _loginCompleted;
  String? get lastError => _lastError;
  String? get notice => _notice;
  bool get lastHeartbeatOk => _lastHeartbeatOk;
  DateTime? get lastHeartbeatAt => _lastHeartbeatAt;

  /// 自动登录是否开启（且未过期）。
  bool get autoLoginEnabled => _store.autoLoginEnabled;

  /// 自动登录到期时间（开启后 1 年）。
  DateTime? get autoLoginExpiresAt => _store.autoLoginExpiresAt;

  /// 正在用保存的账号密码自动登录（门禁页据此显示「自动登录中」）。
  bool get autoLoginRunning => _autoLoginRunning;

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
      // 没有会话时先试自动登录（勾过且未满 1 年）；失败就停在登录页
      await _tryAutoLogin();
      _initialized = true;
      notifyListeners();
      return;
    }

    await _waitUntilAttached();
    final authData = _store.authData;
    if (authData == null || authData.isEmpty) {
      await _handleSessionExpired('登录状态已失效，请重新登录');
      await _tryAutoLogin();
      return;
    }

    final stillValid =
        await v2BoardClient.checkLogin(_store.apiBaseUrl, authData);
    if (stillValid == false) {
      // token 过期是常态（面板 JWT 不续期），这里正是自动登录该接管的地方
      await _handleSessionExpired('登录状态已失效，请重新登录');
      await _tryAutoLogin();
      return;
    }
    if (stillValid == null) {
      // 网络/域名问题导致判断不了：沿用本地会话（离线配置本身可用），
      // 不要因为一次超时就把用户踢回登录页。
      commonPrint.log('[V2Board] 登录态校验失败（网络异常），沿用本地会话');
    }

    // 已有 Dawn 订阅就用旧的（离线配置本身可用），避免每次启动重复导入/丢失节点选择
    await _afterLogin(importProfile: !hasDawnProfile());
    _initialized = true;
    notifyListeners();
  }

  /// 登录：账号密码 → 设备注册 → 专属订阅 → 导入订阅 → 启动心跳/域名探测。
  ///
  /// [autoLogin] 三态：
  /// - `true`：登录成功后加密保存账号密码并重置 1 年有效期（用户在登录页勾选）
  /// - `false`：清除已保存的自动登录凭据（用户取消勾选）
  /// - `null`：不动凭据（自动登录自身调用，不能顺手把有效期又续一年）
  ///
  /// [silent] 用于自动登录：不覆盖提示文案，避免启动时弹「登录成功」。
  Future<void> login({
    required String email,
    required String password,
    required String panelUrl,
    bool? autoLogin,
    bool silent = false,
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
      // 登录接口成功 = 已登录。设备注册 / 订阅解析是「登录后的增强步骤」：
      // 它们失败不能让整体登录判失败，否则下面 catch 会 clearSession，并让
      // _tryAutoLogin 认为登录失败而删掉免密凭据（现象：免密突然永久失效、必须手输密码）。
      _loginCompleted = true;

      // 注册设备（带回环境画像），拿 device_id / totp_secret / 域名池
      Map<String, dynamic>? device;
      try {
        device = await SecurityReportService.instance.registerWithProfile();
      } catch (e) {
        commonPrint.log(
        '[V2Board] 设备注册失败，回退普通订阅: ${sanitizeV2BoardLog(e)}',
      );
      }

      try {
        // 优先用专属订阅（TOTP 签名），没有设备时退回普通订阅
        _store.setSubscribeUrl(await _resolveSubscribeUrl());
        // 静默重登（silent）只在还没有 Dawn 配置时导入一次、且不替换：
        // JWT 两小时就过期，重登不该把用户正在用的配置整个换掉重连。
        await _afterLogin(
          importProfile: !silent || !hasDawnProfile(),
          replaceExisting: !silent,
        );
      } catch (e) {
        commonPrint.log(
        '[V2Board] 登录后订阅准备失败: ${sanitizeV2BoardLog(e)}',
      );
        _lastError = '已登录，但订阅准备失败，请稍后点「刷新订阅」重试';
        // 订阅没准备好也要把心跳/域名探测挂上，否则面板会一直显示「从未上报」
        _startServices();
      }

      if (!silent) {
        _notice = device == null ? '登录成功（设备注册失败，已回退普通订阅）' : '登录成功';
      }

      // 自动登录凭据：勾选就加密保存并重置 1 年有效期，取消勾选就删掉密码。
      if (autoLogin == true) {
        final saved = await _store.saveAutoLogin(
          email: email.trim(),
          password: password,
        );
        if (!saved && !silent) {
          _notice = '登录成功，但自动登录保存失败（系统加密存储不可用）';
        }
      } else if (autoLogin == false) {
        await _store.clearAutoLogin();
      }
    } on V2BoardException catch (e) {
      _lastError = e.message;
      _loginCompleted = false;
      _lastFailureNetwork = e.isNetwork;
      // 登录链路失败时清掉已落盘的半成品会话：否则 authData 已存在，
      // 门禁会误以为已登录直接放行，但心跳/探测/订阅都没启动（表现为「尚未上报」）。
      // 但「网络/面板不可达」例外：保留会话才能让已登录用户继续用本地配置。
      if (!e.isNetwork) {
        await _store.clearSession();
      }
      _refreshFromStore();
    } catch (e) {
      _lastError = '登录失败：${sanitizeV2BoardLog(e)}';
      _loginCompleted = false;
      _lastFailureNetwork = true;
      // 未知异常按「暂时不可用」处理，保留会话，避免一次抖动就掉线。
      _refreshFromStore();
    } finally {
      _setBusy(false);
    }
  }

  /// 用保存的账号密码自动登录；返回是否成功。
  ///
  /// 失败时**不一定**删凭据：只有「账号/密码本身不可用」才删，
  /// 网络抖动、面板 5xx、订阅解析失败都保留，下次启动继续静默重试。
  Future<bool> _tryAutoLogin() async {
    if (!_store.autoLoginEnabled) {
      return false;
    }
    final credential = await _store.readAutoLogin();
    if (credential == null) {
      await _store.clearAutoLogin();
      notifyListeners();
      return false;
    }
    debugPrint('[AutoLogin] 使用保存的账号自动登录: ${credential.email}');
    _autoLoginRunning = true;
    _lastError = null;
    notifyListeners();
    // 订阅导入要写 profile，得等 core 挂上之后再走，否则导入会失败
    await _waitUntilAttached();
    try {
      await login(
        email: credential.email,
        password: credential.password,
        panelUrl: _store.panelUrl,
        silent: true,
      );
    } finally {
      _autoLoginRunning = false;
      notifyListeners();
    }
    final ok = _store.hasSession && _loginCompleted;
    if (ok) {
      debugPrint('[AutoLogin] 自动登录成功');
    } else {
      final message = _lastError ?? '';
      // 只有「凭据/账号本身不可用」才删掉保存的密码。网络抖动、面板 5xx、
      // 订阅解析失败都必须保留凭据，下次启动继续静默重试 —— 否则一次抖动
      // 就永久变成手工登录（2026-11-18 用户反馈的「免密又失效了」就是这个）。
      // 网络/面板不可达时无论如何都不删凭据：那不是账号问题。
      final credentialError = !_lastFailureNetwork &&
          (message.contains('密码') ||
              message.contains('邮箱') ||
              message.contains('账号') ||
              message.contains('封禁') ||
              message.contains('过期') ||
              message.contains('请输入面板地址'));
      if (credentialError) {
        debugPrint('[AutoLogin] 账号凭据类错误，清除保存的凭据: $message');
        await _store.clearAutoLogin();
        _lastError = '账号或密码已失效，请重新登录';
      } else {
        debugPrint('[AutoLogin] 非凭据类失败，保留凭据下次重试: $message');
        _lastError = message.isEmpty
            ? '自动登录失败，请重新登录'
            : '自动登录失败，请重新登录（$message）';
      }
      notifyListeners();
    }
    return ok;
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
    // 长期 token 从 URL 移到 X-Subscribe-Token 请求头（S-35）：
    // URL 只保留 2 分钟时效签名，避免 token 进入 CDN/反代/本地日志与 Referer。
    // 下载侧由 ProfilesAction._download 对 Dawn profile 统一补这个头。
    final tokenlessUrl = _stripSubscribeToken(usableSubscribeUrl);
    final deviceId = _store.deviceId;
    final totpSecret = _store.totpSecret;
    if (deviceId != null &&
        deviceId.isNotEmpty &&
        totpSecret != null &&
        totpSecret.isNotEmpty) {
      final signedUrl = v2BoardClient.buildSignedSubscribeUrl(
        subscribeUrl: tokenlessUrl,
        deviceId: deviceId,
        totpSecret: totpSecret,
      );
      // enc=1：让服务端把专属订阅正文用 AES-256-GCM 加密下发
      // （只有通过设备校验的 app=flclash 才加密；老服务端会忽略该参数）。
      return signedUrl.contains('enc=') ? signedUrl : '$signedUrl&enc=1';
    }
    return v2BoardClient.buildPlainSubscribeUrl(tokenlessUrl);
  }

  /// 去掉订阅 URL 里的长期 `token` 参数（改走请求头）。
  ///
  /// 面板 `Client` 中间件优先读 `X-Subscribe-Token`，同时兼容 `?token=`
  /// （浏览器直接打开订阅链接的产品形态依赖它），所以移除后不会 403。
  String _stripSubscribeToken(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.queryParameters.containsKey('token')) {
      return url;
    }
    final query = Map<String, String>.from(uri.queryParameters)..remove('token');
    return uri.replace(queryParameters: query).toString();
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
    // 每次登录成功都重新解析订阅地址：面板的 subscribe token 可能已经轮换
    // （例如后台强制重置过期订阅），沿用本地缓存的旧 URL 会一直 403。
    // 面板不可达时才回退到缓存的 URL（本地配置本身仍可用）。
    String? url;
    try {
      url = await _resolveSubscribeUrl();
    } catch (e) {
      commonPrint.log(
        '[V2Board] 订阅地址解析失败，沿用本地配置: ${sanitizeV2BoardLog(e)}',
      );
    }
    url ??= _store.subscribeUrl;
    if (url == null || url.isEmpty) {
      _startServices();
      return;
    }
    _store.setSubscribeUrl(url);
    _startServices();
    if (importProfile) {
      await _importProfile(url, replaceExisting: replaceExisting);
    }
  }

  /// 启动心跳与域名探测。订阅是否就绪都必须调用：
  /// 面板的「在线/从未上报」只认心跳，订阅失败不该连带心跳也不启动。
  void _startServices() {
    HeartbeatService.instance.onResult = _onHeartbeatResult;
    HeartbeatService.instance.start(
      interval: Duration(seconds: _store.heartbeatIntervalSeconds),
    );
    DomainProbeService.instance.onOutcome = (_) => notifyListeners();
    DomainProbeService.instance.start();

    // 只在登录后检查客户端更新（面板清单优先，GitHub 兜底）。
    // 后台检查静默；发现新版本时回调给 UI 弹窗（强制更新不可取消）。
    UpdateService.instance.startAutoCheck(
      onUpdateAvailable: () => unawaited(checkUpdateSilently()),
    );
    _startDawnRefreshTask();

    _refreshFromStore();
    notifyListeners();
  }

  /// Dawn 专属订阅的 URL 是 2 分钟有效的 TOTP 签名，上游「按 URL 直接下载」
  /// 的自动更新必然 403 —— 这里单独定时：到期就重新签发 + 重新导入。
  /// 每小时只在本地读一次 lastUpdateDate；距上次更新超过 autoUpdateDuration
  /// （默认 24 小时）才真正重新签发下载，也就是**每天最多自动更新一次**。
  void _startDawnRefreshTask() {
    _dawnRefreshTimer?.cancel();
    _dawnRefreshTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(_refreshDawnProfileIfStale()),
    );
    unawaited(_refreshDawnProfileIfStale());
  }

  Future<void> _refreshDawnProfileIfStale() async {
    if (!_store.hasSession || _refreshingDawnProfile) {
      return;
    }
    final profiles = globalState.container.read(profilesProvider);
    final dawn = profiles
        .where((profile) => profile.label == dawnProfileLabel)
        .firstOrNull;
    if (dawn == null || !dawn.autoUpdate) {
      return;
    }
    final stale = dawn.lastUpdateDate
            ?.add(dawn.autoUpdateDuration)
            .isBeforeNow ??
        true;
    if (!stale) {
      return;
    }
    _refreshingDawnProfile = true;
    try {
      await refreshSubscribe();
    } finally {
      _refreshingDawnProfile = false;
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
        commonPrint.log(
          '[V2Board] 订阅域名不可用，改用当前 API 域名重试: '
          '${sanitizeV2BoardLog(e)}',
        );
        try {
          await addDawnProfileFromLink(fallbackUrl, replace: replaceExisting);
          return;
        } catch (e2) {
          _lastError = '订阅已获取，但导入失败：${sanitizeV2BoardLog(e2)}';
          notifyListeners();
          return;
        }
      }
      commonPrint.log(
        '[V2Board] 导入订阅失败: ${sanitizeV2BoardLog(e)}',
      );
      _lastError = '订阅已获取，但导入失败：${sanitizeV2BoardLog(e)}';
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
    if (result.isDeviceRevoked) {
      // H-09：心跳 403 是 JWT 已通过、但面板拒绝这台设备（被吊销/解绑/超限）。
      // 静默重登修不好这种情况，不能和 JWT 过期混在一起反复重登。
      _handleDeviceRevoked(result.message);
      return;
    }
    if (result.isAuthExpired) {
      unawaited(_recoverSession());
    }
  }

  /// 设备被面板吊销/停用：停止心跳与自动重登，提示用户处理。
  void _handleDeviceRevoked(String? message) {
    HeartbeatService.instance.stop();
    _lastError = (message == null || message.isEmpty)
        ? '设备已被面板限制，请重新登录或联系客服'
        : message;
    _notice = '设备已被限制，请重新登录或联系客服';
    commonPrint.log('[V2Board] 设备被面板拒绝: ${_lastError ?? ''}');
    notifyListeners();
  }

  /// 心跳 401/403：面板 JWT 默认只活 2 小时（`v2board.jwt_ttl=7200`，不续期），
  /// 所以这不是「账号出问题」，而是常态过期 —— 先用保存的账号静默重登，
  /// 成功就无缝继续（用户看不到登录页），失败才退回登录页。
  Future<void> _recoverSession() async {
    if (_recoveringSession) {
      return;
    }
    // 退避：刚因面板不可达失败过，3 分钟内不再重试，避免每 60 秒一轮重登风暴。
    final lastNetworkFailure = _lastNetworkRecoverAt;
    if (lastNetworkFailure != null &&
        DateTime.now().difference(lastNetworkFailure) <
            const Duration(minutes: 3)) {
      return;
    }
    _recoveringSession = true;
    try {
      if (await _tryAutoLogin()) {
        _lastNetworkRecoverAt = null;
        debugPrint('[V2Board] JWT 过期，已静默重登');
        return;
      }
      if (_lastFailureNetwork) {
        // 面板暂时不可达（不是账号问题）：保留登录态和本地配置继续工作，
        // 等心跳下一轮自动重试。绝不能在这里踢回登录页——否则面板抖一下
        // 全体客户端都会被迫重新登录（2026-11-21 事故）。
        _lastNetworkRecoverAt = DateTime.now();
        commonPrint.log('[V2Board] 面板暂时不可达，保留会话等待自动重试');
        _notice = '面板暂时不可用，客户端会继续使用当前配置';
        notifyListeners();
        return;
      }
      await _handleSessionExpired(null);
      _lastError ??= '登录状态已失效，请重新登录';
      notifyListeners();
    } finally {
      _recoveringSession = false;
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
      _lastError = '刷新订阅失败：${sanitizeV2BoardLog(e)}';
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
    // 主动退出 = 明确不要自动登录了，连同加密保存的密码一起删掉
    await _store.clearAutoLogin();
    await _handleSessionExpired(null);
  }


  Future<void> _handleSessionExpired(String? message) async {
    HeartbeatService.instance.stop();
    DomainProbeService.instance.stop();
    HeartbeatService.instance.onResult = null;
    DomainProbeService.instance.onOutcome = null;
    UpdateService.instance.stopAutoCheck();
    _dawnRefreshTimer?.cancel();
    _dawnRefreshTimer = null;
    // 只清会话，保留面板地址/邮箱：自动登录要用同一个面板，登录页也能回填
    await _store.clearSession();
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
