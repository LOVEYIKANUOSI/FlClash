import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';

/// Windows 系统 IPv6 的开关状态（只看「系统有没有把它禁掉」，不代表上游网络支持 IPv6）。
class SystemIpv6Status {
  const SystemIpv6Status({
    required this.registryDisabled,
    required this.bindingEnabled,
    required this.hasAdapter,
    this.error,
  });

  /// 注册表 `Tcpip6\Parameters\DisabledComponents` 非 0 = 被策略/优化工具禁过。
  final bool registryDisabled;

  /// 是否至少有一个已连接网卡启用了 `ms_tcpip6` 绑定。
  final bool bindingEnabled;

  /// 是否存在已连接的网卡。
  final bool hasAdapter;

  final String? error;

  /// 系统层面看起来已启用。
  bool get enabled => hasAdapter && bindingEnabled && !registryDisabled;

  /// 系统确实把 IPv6 关掉了（而不是上游不给 IPv6）。
  bool get disabled => hasAdapter && (registryDisabled || !bindingEnabled);

  @override
  String toString() =>
      'SystemIpv6Status(registryDisabled: $registryDisabled, '
      'bindingEnabled: $bindingEnabled, hasAdapter: $hasAdapter, '
      'error: $error)';
}

/// Windows 系统 IPv6 的检测与启用。
///
/// 客户端通过 `windows/runner/runner.exe.manifest` 的
/// `requestedExecutionLevel = requireAdministrator` 以管理员身份启动，
/// 因此这里检测到系统 IPv6 被禁用时可以直接改注册表/网卡绑定，不需要再弹 UAC。
///
/// 检测（只读）：`Get-NetAdapter` + `Get-NetAdapterBinding` +
/// 读注册表 `Tcpip6\Parameters\DisabledComponents`。
///
/// 启用：写临时 PowerShell 脚本，把 `DisabledComponents` 置 0 并给所有
/// 已连接网卡启用 `ms_tcpip6` 绑定，随后轮询状态确认生效。
class SystemIpv6 {
  SystemIpv6._();

  static final SystemIpv6 instance = SystemIpv6._();

  static const _pollInterval = Duration(seconds: 2);
  static const _pollTimes = 3;

  /// 检测结果缓存：`inspect()` 要起一个 PowerShell 进程（约 1s），
  /// 后台 IPv6 探测每次都会调它，必须缓存，否则会频繁抢 CPU 造成卡顿感。
  static const _cacheTtl = Duration(minutes: 5);

  bool _attempted = false;
  SystemIpv6Status? _statusCache;
  DateTime? _statusAt;

  /// 是否已经尝试过开启（每进程只跑一次）。
  bool get attempted => _attempted;

  Future<SystemIpv6Status> inspect({bool force = false}) async {
    if (!system.isWindows) {
      return const SystemIpv6Status(
        registryDisabled: false,
        bindingEnabled: true,
        hasAdapter: true,
      );
    }
    final cached = _statusCache;
    final at = _statusAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _cacheTtl) {
      return cached;
    }
    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', _inspectScript],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final output = '${result.stdout}'.trim();
      final line = output.split('\n').lastWhere(
        (value) => value.trim().startsWith('{'),
        orElse: () => '',
      );
      if (line.isEmpty) {
        return SystemIpv6Status(
          registryDisabled: false,
          bindingEnabled: false,
          hasAdapter: false,
          error: '无法解析检测结果: $output',
        );
      }
      final data = jsonDecode(line) as Map<String, dynamic>;
      final status = SystemIpv6Status(
        registryDisabled: data['registryDisabled'] as bool? ?? false,
        bindingEnabled: data['bindingEnabled'] as bool? ?? false,
        hasAdapter: data['hasAdapter'] as bool? ?? false,
      );
      _statusCache = status;
      _statusAt = DateTime.now();
      return status;
    } catch (e) {
      return SystemIpv6Status(
        registryDisabled: false,
        bindingEnabled: false,
        hasAdapter: false,
        error: e.toString(),
      );
    }
  }

  /// 当前进程是否有管理员权限。
  Future<bool> isElevated() async {
    if (!system.isWindows) {
      return false;
    }
    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', _elevatedScript],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return '${result.stdout}'.toLowerCase().contains('true');
    } catch (e) {
      commonPrint.log('[IPv6] 管理员权限检测失败: $e');
      return false;
    }
  }

  /// 检测系统 IPv6；如果被系统禁用，则直接执行开启脚本。
  ///
  /// 客户端已通过 manifest 以管理员身份启动，所以这里不需要再 UAC 提权；
  /// 若因某种原因不是管理员（例如被调试器降权启动），只提示不硬改。
  ///
  /// 返回 true 表示「系统层面现在已启用」（原本就开着也算）。
  Future<bool> ensureEnabled() async {
    final status = await inspect();
    if (status.enabled) {
      return true;
    }
    if (!status.disabled) {
      // 没有网卡或检测失败，不做任何系统改动。
      return false;
    }
    if (_attempted) {
      return false;
    }
    _attempted = true;
    if (!await isElevated()) {
      commonPrint.log('[IPv6] 系统 IPv6 被禁用，但当前进程不是管理员，无法自动开启: $status');
      dialogs.showBanner('需要以管理员身份运行才能开启系统 IPv6');
      return false;
    }
    commonPrint.log('[IPv6] 系统 IPv6 被禁用，正在以管理员权限开启: $status');
    final executed = await _runEnableScript();
    if (!executed) {
      return false;
    }
    for (var i = 0; i < _pollTimes; i++) {
      await Future<void>.delayed(_pollInterval);
      // 刚改过注册表/网卡绑定：必须跳过缓存重新检测。
      final next = await inspect(force: true);
      if (next.enabled) {
        commonPrint.log('[IPv6] 系统 IPv6 已启用');
        return true;
      }
    }
    commonPrint.log('[IPv6] 开启脚本执行后仍未检测到系统 IPv6 启用');
    return false;
  }

  Future<bool> _runEnableScript() async {
    try {
      final scriptFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}dawn-enable-ipv6.ps1',
      );
      await scriptFile.writeAsString(_enableScript, flush: true);
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) {
        commonPrint.log('[IPv6] 开启脚本失败(${result.exitCode}): ${result.stderr}');
        return false;
      }
      return true;
    } catch (e) {
      commonPrint.log('[IPv6] 开启脚本异常: $e');
      return false;
    }
  }

  static const _elevatedScript = r'''
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
''';

  static const _inspectScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$registryDisabled = $false
$reg = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents).DisabledComponents
if ($null -ne $reg -and $reg -ne 0) { $registryDisabled = $true }
$adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
$bindingEnabled = $false
foreach ($adapter in $adapters) {
  $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6'
  if ($null -ne $binding -and $binding.Enabled) { $bindingEnabled = $true }
}
[pscustomobject]@{
  registryDisabled = $registryDisabled
  bindingEnabled = $bindingEnabled
  hasAdapter = ($adapters.Count -gt 0)
} | ConvertTo-Json -Compress
''';

  static const _enableScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$reg = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$current = (Get-ItemProperty -Path $reg -Name DisabledComponents).DisabledComponents
if ($null -ne $current -and $current -ne 0) {
  Set-ItemProperty -Path $reg -Name DisabledComponents -Value 0 -Type DWord
}
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
  Enable-NetAdapterBinding -Name $_.Name -ComponentID 'ms_tcpip6'
}
exit 0
''';
}
