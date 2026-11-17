import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';

import 'app_config.dart';
import 'auth_store.dart';
import 'client.dart';

class DomainProbeResult {
  final String domain;
  final bool reachable;
  final int latencyMs;
  final int statusCode;
  final String? error;

  const DomainProbeResult({
    required this.domain,
    required this.reachable,
    required this.latencyMs,
    this.statusCode = 0,
    this.error,
  });

  /// Cloudflare 502/504 这类「连得上但源站挂了」也算不可用。
  bool get healthy => reachable && statusCode > 0 && statusCode < 500;
}

class DomainSwitchOutcome {
  final List<DomainProbeResult> all;
  final List<DomainProbeResult> reachable;
  final String? newActive;
  final String? error;

  const DomainSwitchOutcome({
    required this.all,
    required this.reachable,
    this.newActive,
    this.error,
  });

  bool get switched => newActive != null;
}

/// 客户端专属域名探测与自动切换。
///
/// 定时探测域名池；active 域名不可达但池内有可用域名时，用可用域名上报面板，
/// 面板切换子域名并下发新域名池。
class DomainProbeService {
  DomainProbeService._();

  static final DomainProbeService instance = DomainProbeService._();

  void Function(DomainSwitchOutcome outcome)? onOutcome;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: AppConfig.probeTimeout,
      receiveTimeout: AppConfig.probeTimeout,
      validateStatus: (_) => true,
    ),
  );

  Timer? _timer;
  DomainSwitchOutcome? _lastOutcome;
  int _consecutiveFailures = 0;

  DomainSwitchOutcome? get lastOutcome => _lastOutcome;

  bool get isRunning => _timer != null;

  void start() {
    stop();
    _timer = Timer.periodic(AppConfig.probeInterval, (_) => checkAndSwitch());
    unawaited(checkAndSwitch());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<DomainProbeResult> probe(String domain) async {
    final stopwatch = Stopwatch()..start();
    final target = '${AppConfig.normalizeDomain(domain)}/';
    try {
      final response = await _dio.get(target, options: Options(followRedirects: false));
      stopwatch.stop();
      return DomainProbeResult(
        domain: domain,
        reachable: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        statusCode: response.statusCode ?? 0,
      );
    } catch (e) {
      stopwatch.stop();
      return DomainProbeResult(
        domain: domain,
        reachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  Future<DomainSwitchOutcome> checkAndSwitch() async {
    final authStore = AuthStore();
    await authStore.init();
    final pool = authStore.domainPool;
    final authData = authStore.authData;
    final deviceId = authStore.deviceId;

    final active = authStore.activeDomain;
    // 面板没配置客户端域名时会下发 client.example.invalid 之类的占位符，直接忽略。
    final domains = pool.isEmpty ? [active] : pool;
    final probeTargets =
        domains.where(AppConfig.isUsableDomain).toList(growable: false);
    if (probeTargets.isEmpty) {
      return _finish(
        const DomainSwitchOutcome(
          all: [],
          reachable: [],
          error: '暂无可用客户端域名',
        ),
      );
    }
    final results = await Future.wait(probeTargets.map(probe));
    final reachable = results.where((r) => r.reachable).toList();

    // active 域名可达 → 无需切换
    if (reachable.any((r) => r.domain == active)) {
      _consecutiveFailures = 0;
      return _finish(DomainSwitchOutcome(all: results, reachable: reachable));
    }

    _consecutiveFailures++;

    // active 不可达，但池内有可用域名 → 用可用域名上报切换
    if (reachable.isNotEmpty &&
        authData != null &&
        authData.isNotEmpty &&
        deviceId != null &&
        deviceId.isNotEmpty) {
      final reporter = reachable.first.domain;
      try {
        final result = await v2BoardClient.reportDomain(
          AppConfig.normalizeDomain(reporter),
          authData,
          deviceId: deviceId,
          blockedDomain: active,
        );
        final newActive = result?.active;
        final newPool = result?.domainPool ?? const <String>[];
        if (newActive != null && newActive.isNotEmpty) {
          await authStore.saveDomains(
            activeDomain: newActive,
            domainPool: newPool.isEmpty ? pool : newPool,
          );
          _consecutiveFailures = 0;
          return _finish(
            DomainSwitchOutcome(
              all: results,
              reachable: reachable,
              newActive: newActive,
            ),
          );
        }
      } catch (e) {
        return _finish(
          DomainSwitchOutcome(
            all: results,
            reachable: reachable,
            error: e.toString(),
          ),
        );
      }
    }

    // 全部不可达或未登录 → 等下一轮（定时器天然指数退避）
    return _finish(
      DomainSwitchOutcome(
        all: results,
        reachable: reachable,
        error: reachable.isEmpty ? '全部域名不可达' : '未登录，无法上报切换',
      ),
    );
  }

  DomainSwitchOutcome _finish(DomainSwitchOutcome outcome) {
    _lastOutcome = outcome;
    commonPrint.log(
      '[DomainProbe] 失败计数=$_consecutiveFailures '
      '可达=${outcome.reachable.length}/${outcome.all.length} '
      'active=${outcome.newActive ?? '-'}',
    );
    onOutcome?.call(outcome);
    return outcome;
  }
}
