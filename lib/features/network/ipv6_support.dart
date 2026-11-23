import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';

import 'system_ipv6.dart';

/// 一次 IPv6 可用性探测的结果。
class Ipv6Probe {
  const Ipv6Probe({
    required this.systemEnabled,
    required this.reachable,
    this.address,
    this.error,
  });

  /// 本机是否枚举到非 link-local 的 IPv6 地址。
  final bool systemEnabled;

  /// 能否与外部 IPv6 目标建立 TCP 连接。
  final bool reachable;

  /// 探测到的第一个全局 IPv6 地址。
  final String? address;

  /// 探测失败时的错误信息（仅日志用）。
  final String? error;

  bool get usable => systemEnabled && reachable;

  @override
  String toString() =>
      'Ipv6Probe(systemEnabled: $systemEnabled, reachable: $reachable, '
      'address: $address, error: $error)';
}

/// 客户端 IPv6 强制策略（2026-11-21 起不再提供开关）。
///
/// 产品要求：
/// - IPv6 始终开启，用户不可关闭（设置页不再显示该选项）；
/// - 在「测试节点」和「使用节点」之前自动检查并打开 IPv6。
///
/// 实现上做两件事：
/// 1. [enforce] 把 VPN(TUN) 的 IPv6 与内核 general 的 IPv6 两个开关都置为 true；
/// 2. [probe] 检查本机 IPv6 地址与实际连通性，供上层决定是否提示。
class Ipv6Support {
  Ipv6Support._();

  static final Ipv6Support instance = Ipv6Support._();

  /// 探测目标（host, port），只做 TCP 握手、不发业务请求。
  ///
  /// 必须**多个目标**且来自不同网络：早先只探测 Cloudflare 的
  /// `2606:4700:4700::1111`，该地址在部分运营商/网络下不可达，
  /// 会导致「IPv6 明明能用却提示不可用」的误报（2026-11-23 用户反馈）。
  /// 任一目标 TCP 可达即视为出口可用。
  static const _probeTargets = <(String, int)>[
    ('2400:3200::1', 53), // 阿里云公共 DNS（国内可达性好）
    ('2001:4860:4860::8888', 53), // Google DNS
    ('2606:4700:4700::1111', 443), // Cloudflare DNS（DoH）
  ];

  /// 单次探测超时：本机 IPv6 不通时这段等待会落在后台任务里，
  /// 不能太长（会被用户感知成「点测试延迟卡一下」）。
  static const _probeTimeout = Duration(seconds: 2);

  /// 探测结果缓存 5 分钟：IPv6 出口是否可达不会秒级变化，
  /// 每次测试都重探会让后台一直占着 socket/枚举网卡。
  static const _probeTtl = Duration(minutes: 5);

  DateTime? _probeAt;
  Ipv6Probe? _probeCache;
  bool _noticeShown = false;
  bool _checking = false;

  /// 强制打开两条 IPv6 链路；幂等，只在关闭时才写 state。
  ///
  /// 1. `VpnProps.ipv6`：TUN/VPN 层接收 IPv6 流量；
  /// 2. `PatchClashConfig.ipv6` **且**把 `GeneralOverrideKey.ipv6` 加入
  ///    `generalOverrideKeys` —— 内核的 `ipv6` 只有出现在覆盖键里才会被
  ///    下发给内核（见 `PatchClashConfigExt.toUpdateParams` 的 `_picked`），
  ///    只改值不加键等于没开。
  void enforce() {
    final container = globalState.container;
    if (!container.read(vpnSettingProvider).ipv6) {
      container
          .read(vpnSettingProvider.notifier)
          .update((state) => state.copyWith(ipv6: true));
    }
    final clash = container.read(patchClashConfigProvider);
    final needsValue = !clash.ipv6;
    final needsOverrideKey =
        !clash.generalOverrideKeys.contains(GeneralOverrideKey.ipv6);
    if (needsValue || needsOverrideKey) {
      container
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) => state.copyWith(
              ipv6: true,
              generalOverrideKeys: {
                ...state.generalOverrideKeys,
                GeneralOverrideKey.ipv6,
              },
            ),
          );
    }
  }

  /// 探测本机 IPv6（默认 60 秒缓存）。
  Future<Ipv6Probe> probe({bool force = false}) async {
    final at = _probeAt;
    final cached = _probeCache;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _probeTtl) {
      return cached;
    }
    final result = await _doProbe();
    _probeCache = result;
    _probeAt = DateTime.now();
    return result;
  }

  Future<Ipv6Probe> _doProbe() async {
    final address = await _firstGlobalIpv6();
    if (address == null) {
      return const Ipv6Probe(systemEnabled: false, reachable: false);
    }
    final failures = <String>[];
    final reachable = await _anyProbeTargetReachable(failures);
    return Ipv6Probe(
      systemEnabled: true,
      reachable: reachable,
      address: address,
      error: reachable ? null : failures.join('; '),
    );
  }

  /// 并行探测所有目标，任一 TCP 握手成功即返回 true。
  Future<bool> _anyProbeTargetReachable(List<String> failures) async {
    final results = await Future.wait(
      _probeTargets.map((target) async {
        try {
          final socket = await Socket.connect(
            target.$1,
            target.$2,
            timeout: _probeTimeout,
          );
          socket.destroy();
          return true;
        } catch (e) {
          failures.add('${target.$1}:${target.$2} $e');
          return false;
        }
      }),
    );
    return results.any((reachable) => reachable);
  }

  Future<String?> _firstGlobalIpv6() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv6,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv6) {
            continue;
          }
          if (isLinkLocal(address.address)) {
            continue;
          }
          return address.address;
        }
      }
    } catch (e) {
      commonPrint.log('[IPv6] 枚举本机地址失败: $e');
    }
    return null;
  }

  /// 是否是 IPv6 link-local 地址（fe80::/10）。
  @visibleForTesting
  static bool isLinkLocal(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    final firstSegment = normalized.split(':').first.padLeft(4, '0');
    final prefix = int.tryParse(firstSegment, radix: 16);
    if (prefix == null) {
      return false;
    }
    return (prefix & 0xffc0) == 0xfe80;
  }

  /// 测试节点 / 使用节点之前的统一入口：强制开启 + 探测 + 必要时提示一次。
  ///
  /// Windows 上如果本机完全枚举不到全局 IPv6，会先确认是不是系统层面被禁用：
  /// 是的话通过 UAC 提权打开系统 IPv6（`SystemIpv6.ensureEnabled`，每进程只请求
  /// 一次），再重新探测。
  Future<Ipv6Probe> ensureBeforeUse() async {
    enforce();
    if (_checking) {
      return probe();
    }
    _checking = true;
    try {
      var result = await probe();
      if (!result.systemEnabled && system.isWindows) {
        final systemEnabled = await SystemIpv6.instance.ensureEnabled();
        if (systemEnabled) {
          result = await probe(force: true);
        }
      }
      if (!result.systemEnabled) {
        _showNoticeOnce('未检测到本机 IPv6 地址，IPv6 出口节点可能无法使用');
      } else if (!result.reachable) {
        // 外网探测受运营商/当前节点影响大（个别目标不可达 ≠ 本机 IPv6 不可用），
        // 只记日志，不弹横幅误导用户；节点真的连不通会在测速结果里体现。
        commonPrint.log('[IPv6] 外网探测目标均不可达（不代表本机 IPv6 不可用）');
      }
      return result;
    } finally {
      _checking = false;
    }
  }

  /// 启动后的后台检查：只记录日志，不弹 UAC（等用户真正测试/使用节点时再提权）。
  void checkAfterStart() {
    unawaited(_probeSilently());
  }

  /// 记录当前进程是否以管理员运行（排查系统 IPv6/网卡操作失败时用）。
  void logElevation() {
    unawaited(_logElevation());
  }

  Future<void> _logElevation() async {
    if (!system.isWindows) {
      return;
    }
    final elevated = await SystemIpv6.instance.isElevated();
    commonPrint.log('[IPv6] 管理员权限: $elevated');
  }

  Future<void> _probeSilently() async {
    enforce();
    final result = await probe();
    if (!result.systemEnabled) {
      commonPrint.log('[IPv6] 启动检查：未检测到本机 IPv6 地址');
    } else if (!result.reachable) {
      commonPrint.log('[IPv6] 启动检查：外网探测目标均不可达（本机仍有全局地址）');
    }
  }

  void _showNoticeOnce(String message) {
    if (_noticeShown) {
      return;
    }
    _noticeShown = true;
    commonPrint.log('[IPv6] $message');
    dialogs.showBanner(message);
  }
}
