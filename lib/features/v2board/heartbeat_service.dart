import 'dart:async';

import 'package:fl_clash/common/common.dart';

import 'auth_store.dart';
import 'client.dart';
import 'security_report_service.dart';

/// 心跳上报服务。
///
/// 登录成功后启动，按面板下发的间隔（默认 60s）上报在线状态。
/// 参考实现把 403 也当成功、且登出后不停表；这里回调给 V2BoardState，
/// 由状态层决定是否踢回登录页。
class HeartbeatService {
  HeartbeatService._();

  static final HeartbeatService instance = HeartbeatService._();

  void Function(V2BoardHeartbeatResult result)? onResult;

  Timer? _timer;
  Duration _interval = const Duration(seconds: 60);
  bool _beating = false;

  bool get isRunning => _timer != null;

  V2BoardHeartbeatResult? lastResult;

  void start({Duration? interval}) {
    stop();
    if (interval != null && interval.inSeconds > 0) {
      _interval = interval;
    }
    _timer = Timer.periodic(_interval, (_) => beat());
    unawaited(beat());
  }

  /// 仅在间隔变化时重建定时器（不立即触发 beat，避免重启风暴）。
  void updateInterval(Duration interval) {
    if (interval.inSeconds <= 0 || interval == _interval) {
      return;
    }
    _interval = interval;
    if (_timer == null) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => beat());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> beat() async {
    if (_beating) {
      return;
    }
    _beating = true;
    try {
      final authStore = AuthStore();
      await authStore.init();
      final authData = authStore.authData;
      if (authData == null || authData.isEmpty) {
        return;
      }
      V2BoardHeartbeatResult result;
      try {
        result = await v2BoardClient.heartbeat(
          authStore.apiBaseUrl,
          authData,
          deviceId: authStore.deviceId,
        );
      } catch (e) {
        // 网络/DNS 失败也要回调，否则账户页永远停在「尚未上报」且没有任何提示。
        commonPrint.log('[Heartbeat] 上报失败: $e');
        result = const V2BoardHeartbeatResult(ok: false);
      }
      lastResult = result;
      commonPrint.log(
        '[Heartbeat] ok=${result.ok} status=${result.statusCode} '
        'interval=${result.intervalSeconds}',
      );
      final interval = result.intervalSeconds;
      if (interval != null && interval > 0) {
        updateInterval(Duration(seconds: interval));
      }
      onResult?.call(result);
      if (result.ok) {
        await SecurityReportService.instance.onHeartbeat();
      }
    } finally {
      _beating = false;
    }
  }
}
