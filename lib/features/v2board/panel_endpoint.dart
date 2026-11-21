import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';

import 'app_config.dart';
import 'auth_store.dart';

/// 面板请求的一次通道尝试。
class PanelAttempt {
  /// true = 走用户节点代理；false = 直连。
  final bool useProxy;

  /// 本次尝试使用的基础地址（scheme + host），path/query 沿用失败请求。
  final String baseUrl;

  /// 去重用的通道标识，格式 `direct|proxy:baseUrl`。
  final String id;

  const PanelAttempt({
    required this.useProxy,
    required this.baseUrl,
    required this.id,
  });
}

/// 面板接口的多通道容灾。
///
/// 面板域名可能被墙 / 被 CDN 拦 / 面板自身短时故障。每次请求按下面的顺序
/// 自动换通道，避免「面板一挂，所有客户端都不能用」：
///
/// 1. 当前 active 域名直连；
/// 2. 面板下发的域名池（`domain_pool`）里的其它域名直连；
/// 3. 用户自己的节点代理（本机内核 mixed-port）访问上面这些域名。
///
/// 通道全部失败时抛出原始错误，由 [V2BoardClient] 转成「面板暂时不可达」。
class PanelEndpoint {
  PanelEndpoint._();

  static final PanelEndpoint instance = PanelEndpoint._();

  static const connectTimeout = Duration(seconds: 8);
  static const receiveTimeout = Duration(seconds: 15);

  bool _proxyActive = false;

  /// 当前是否处于「直连不可用、改走用户节点代理」的状态。
  ///
  /// 一旦探测到直连失败而代理可用，后续请求把代理放到第一优先，
  /// 避免每个请求都要先等一次直连超时。
  bool get proxyActive => _proxyActive;

  Dio? _proxyDio;
  int? _proxyPort;

  void markDirectSuccess() {
    _proxyActive = false;
  }

  void markProxySuccess() {
    _proxyActive = true;
  }

  /// 本机内核 mixed-port；内核未启动 / 读不到配置时为 null。
  int? get mixedPort {
    try {
      final port = globalState.container
          .read(patchClashConfigProvider)
          .mixedPort;
      return port > 0 ? port : null;
    } catch (_) {
      return null;
    }
  }

  /// 代理通道现在可用吗：内核已启动且未挂起。
  bool get _proxyUsable {
    try {
      return globalState.container.read(isStartProvider) &&
          !globalState.container.read(suspendProvider);
    } catch (_) {
      return false;
    }
  }

  /// 走用户节点的代理通道；mixed-port 变化时重建 Dio。
  Dio? get proxyDio {
    if (!_proxyUsable) {
      _proxyDio = null;
      _proxyPort = null;
      return null;
    }
    final port = mixedPort;
    if (port == null) {
      _proxyDio = null;
      _proxyPort = null;
      return null;
    }
    if (_proxyDio != null && _proxyPort == port) {
      return _proxyDio;
    }
    _proxyPort = port;
    // 内核开了代理认证时 findProxy 需要带 user:pass@，与 FlClashHttpOverrides 一致。
    var userInfo = '';
    try {
      final credentials = globalState.container
          .read(networkSettingProvider)
          .authentication
          .credentials;
      if (credentials.isNotEmpty) {
        userInfo = '${credentials.first}@';
      }
    } catch (_) {}
    final dio = Dio(
      BaseOptions(
        headers: {'User-Agent': browserUa, 'Accept': 'application/json'},
        responseType: ResponseType.json,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        // 与主客户端保持一致：业务错误用非 200 表达，交给上层解析 message。
        validateStatus: (status) => status != null,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()..connectionTimeout = connectTimeout;
        client.findProxy = (_) => 'PROXY ${userInfo}127.0.0.1:$port';
        return client;
      },
    );
    _proxyDio = dio;
    return dio;
  }

  /// 候选 origin：当前 active → 面板下发域名池 → 用户填的面板地址。
  ///
  /// 占位符域名（`client.example.invalid` 等）会被过滤；但用户手填的面板地址
  /// 不再过 [AppConfig.isUsableDomain]——本地联调可能用局域网 IP/端口。
  Future<List<String>> candidates() async {
    final store = AuthStore();
    await store.init();
    final result = <String>[];

    void addDomain(String? raw) {
      final value = AppConfig.normalizeUrl(raw?.trim() ?? '');
      if (value.isEmpty || result.contains(value)) {
        return;
      }
      final host = Uri.tryParse(value)?.host ?? '';
      if (!AppConfig.isUsableDomain(host)) {
        return;
      }
      result.add(value);
    }

    addDomain(store.activeDomain);
    for (final domain in store.domainPool) {
      addDomain(domain);
    }
    final panelUrl = AppConfig.normalizeUrl(store.panelUrl);
    if (panelUrl.isNotEmpty && !result.contains(panelUrl)) {
      result.add(panelUrl);
    }
    return result;
  }

  /// 根据失败请求和已试通道给出下一次尝试；全部试完返回 null。
  Future<PanelAttempt?> nextAttempt(Uri failed, List<String> tried) async {
    final origins = await candidates();
    if (origins.isEmpty) {
      return null;
    }
    final proxy = proxyDio;
    // 直连优先；已经确认直连不可用时代理优先。
    final order = _proxyActive ? const [true, false] : const [false, true];
    for (final useProxy in order) {
      if (useProxy && proxy == null) {
        continue;
      }
      for (final baseUrl in origins) {
        final base = Uri.tryParse(baseUrl);
        if (base == null || base.host.isEmpty) {
          continue;
        }
        final id = '${useProxy ? 'proxy' : 'direct'}:$baseUrl';
        if (tried.contains(id)) {
          continue;
        }
        return PanelAttempt(useProxy: useProxy, baseUrl: baseUrl, id: id);
      }
    }
    return null;
  }

  /// 这个异常值不值得换通道重试。
  ///
  /// 只对「连接层失败 / 超时 / 5xx 源站故障」重试；4xx 是明确的业务错误
  /// （401 未登录、422 参数错误等），换域名/换代理也不会变好。
  static bool isRetryable(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badResponse:
        return (error.response?.statusCode ?? 0) >= 500;
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return false;
    }
  }
}

/// 给面板 Dio 挂的容灾拦截器：失败后自动换「备用域名 / 节点代理」重试。
///
/// 放在拦截器层而不是业务代码里，是为了让所有接口（登录、心跳、订阅、商城、
/// 工单……）自动获得同一套容灾，不用逐个方法改。
class PanelFailoverInterceptor extends Interceptor {
  static const _triedKey = 'panel_failover_tried';
  static const _channelKey = 'panel_failover_channel';

  final Dio Function() directDio;
  final Dio? Function() proxyDio;

  PanelFailoverInterceptor({
    required this.directDio,
    required this.proxyDio,
  });

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final status = response.statusCode ?? 0;
    if (status >= 500) {
      // 面板源站故障（容器挂了 / CF 502）也换通道：换域名或走代理可能能通。
      final synthetic = DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
      final retried = await _attemptNext(synthetic);
      if (retried != null) {
        handler.resolve(retried);
        return;
      }
      handler.next(response);
      return;
    }
    final channel = response.requestOptions.extra[_channelKey];
    if (channel == 'proxy') {
      PanelEndpoint.instance.markProxySuccess();
    } else {
      PanelEndpoint.instance.markDirectSuccess();
    }
    handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!PanelEndpoint.isRetryable(err)) {
      handler.next(err);
      return;
    }
    final retried = await _attemptNext(err);
    if (retried != null) {
      handler.resolve(retried);
      return;
    }
    handler.next(err);
  }

  Future<Response<dynamic>?> _attemptNext(DioException original) async {
    final options = original.requestOptions;
    final tried = <String>[
      ...((options.extra[_triedKey] as List?)?.cast<String>() ?? const []),
    ];
    final channel = (options.extra[_channelKey] as String?) ?? 'direct';
    final currentId = '$channel:${options.uri.origin}';
    if (!tried.contains(currentId)) {
      tried.add(currentId);
    }
    final attempt = await PanelEndpoint.instance.nextAttempt(options.uri, tried);
    if (attempt == null) {
      return null;
    }
    final dio = attempt.useProxy ? proxyDio() : directDio();
    if (dio == null) {
      return null;
    }
    final base = Uri.tryParse(attempt.baseUrl);
    if (base == null) {
      return null;
    }
    // 只换 origin，path/query 原样保留（接口语义不变）。
    final target = options.uri.replace(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
    );
    final next = options.copyWith(
      path: target.toString(),
      extra: {
        ...options.extra,
        _triedKey: tried,
        _channelKey: attempt.useProxy ? 'proxy' : 'direct',
      },
    );
    try {
      return await dio.fetch<dynamic>(next);
    } catch (_) {
      return null;
    }
  }
}
