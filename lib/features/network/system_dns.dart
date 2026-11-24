import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/dns_protection.dart';
import 'package:fl_clash/common/print.dart';

/// 单个网卡的 DNS 配置快照。
class SystemDnsInterface {
  const SystemDnsInterface({
    required this.index,
    required this.alias,
    required this.servers,
  });

  final int index;
  final String alias;
  final List<String> servers;
}

/// 系统 DNS 快照（IPv4 + IPv6），用于退出/停止时恢复。
class SystemDnsSnapshot {
  const SystemDnsSnapshot({required this.ipv4, required this.ipv6});

  final List<SystemDnsInterface> ipv4;
  final List<SystemDnsInterface> ipv6;

  bool get isEmpty => ipv4.isEmpty && ipv6.isEmpty;
}

/// 把系统 DNS 指向本机内核的 DNS 监听端口（127.0.0.1:53）。
///
/// 系统代理模式下，浏览器对 HTTPS 请求发 `CONNECT host:443`，域名由 mihomo
/// 代理解析；但 Chrome 的 DNS 预取、QUIC/HTTP3、以及其它不认代理的程序仍会
/// 直接查系统 DNS，这是 dnsleaktest 里残留「China Telecom」解析器的来源。
///
/// **IPv6 也必须处理**：Windows 会优先用 IPv6 网卡的 DNS（常见 `fe80::1`
/// 路由器），只改 IPv4 的话 `nslookup` 依然走 `fe80::1` → 运营商 DNS。
/// 这里把 IPv6 DNS 也改成 `::1`（内核不监听 IPv6，解析会回退到 IPv4 的
/// `127.0.0.1`），恢复时再写回原值。
///
/// 用 `netsh` 而不是 `Set-DnsClientServerAddress`：实测后者对部分物理网卡
/// （Realtek 5GbE）静默不生效，`netsh interface ipv4 set dnsservers` 生效。
///
/// 备注：本机 UDP `0.0.0.0:53` 常被 Windows 的 Internet Connection Sharing
/// (ICS) 占用，但 `127.0.0.1:53` 仍可绑定，因此内核监听 loopback 而不是 0.0.0.0。
class SystemDnsProtection {
  static final SystemDnsProtection instance = SystemDnsProtection._();

  SystemDnsProtection._();

  static const _loopback = '127.0.0.1';
  static const _loopbackIpv6 = '::1';

  /// 系统 DNS 接管**默认关闭**（2026-11-24 事故后）。
  ///
  /// 接管会把全机 DNS 指向本机内核；一旦进程被强杀/崩溃而退出钩子没跑，
  /// 内核随之消失 → 全机 DNS 解析失败 → 断网。重新启用前必须补齐
  /// 「启动自愈 + 独立看护进程 + 强杀演练」三项（见
  /// `docs/dev/flclash-client.md` §4.13.1）。
  ///
  /// 需要验证时用 `--dart-define=SYSTEM_DNS_TAKEOVER=true` 构建。
  /// 实际取值见 `dns_protection.dart::systemDnsTakeoverEnabled`（同一常量）。
  static const bool takeoverEnabled = systemDnsTakeoverEnabled;

  SystemDnsSnapshot? _snapshot;
  bool _applied = false;

  bool get applied => _applied;

  /// 读取当前所有带 DNS 的网卡配置（IPv4 与 IPv6 分开）。
  Future<SystemDnsSnapshot?> capture() async {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final ipv4 = await _captureFamily(4);
      final ipv6 = await _captureFamily(6);
      return SystemDnsSnapshot(ipv4: ipv4, ipv6: ipv6);
    } catch (error) {
      commonPrint.log('[SystemDns] 读取系统 DNS 失败: $error');
      return null;
    }
  }

  Future<List<SystemDnsInterface>> _captureFamily(int family) async {
    final script =
        'Get-DnsClientServerAddress -AddressFamily IPv$family | '
        'Where-Object { \$_.ServerAddresses.Count -gt 0 } | '
        'Select-Object InterfaceIndex,InterfaceAlias,ServerAddresses | '
        'ConvertTo-Json -Compress';
    final output = await _powershell(script);
    if (output.isEmpty) {
      return const <SystemDnsInterface>[];
    }
    final decoded = jsonDecode(output);
    final items = decoded is List ? decoded : [decoded];
    final interfaces = <SystemDnsInterface>[];
    for (final item in items) {
      if (item is! Map) {
        continue;
      }
      final index = item['InterfaceIndex'];
      final alias = item['InterfaceAlias'];
      final servers = item['ServerAddresses'];
      if (index is! int || alias is! String) {
        continue;
      }
      interfaces.add(
        SystemDnsInterface(
          index: index,
          alias: alias,
          servers: servers is List
              ? servers.whereType<String>().toList()
              : <String>[],
        ),
      );
    }
    return interfaces;
  }

  /// 启动自愈：上次异常退出可能把系统 DNS 留在 `127.0.0.1`/`::1`，
  /// 而本机 53 已无监听（内核随进程消失）→ 全机解析失败、断网。
  ///
  /// 这里检测「DNS 指向 loopback 但 53 不可用」的组合并恢复 DHCP。
  /// 与 [takeoverEnabled] 无关，始终可用（清理历史残留）。
  Future<bool> recoverIfStale() async {
    if (!Platform.isWindows) {
      return false;
    }
    final ipv4 = await _captureFamily(4);
    final ipv6 = await _captureFamily(6);
    final loopbackOnly = ipv4.every(
          (item) => item.servers.every((server) => server == _loopback),
        ) &&
        ipv6.every((item) => item.servers.every((server) => server == _loopbackIpv6));
    if (!loopbackOnly) {
      return false;
    }
    if (await _waitDnsPortReady()) {
      // 内核还活着（正常接管状态），不动。
      return false;
    }
    commonPrint.log(
      '[SystemDns] 检测到上次异常退出残留（DNS→loopback 但 53 无监听），恢复 DHCP',
    );
    for (final item in ipv4) {
      await _netsh([
        'interface',
        'ipv4',
        'set',
        'dnsservers',
        'name=${item.alias}',
        'source=dhcp',
      ]);
    }
    for (final item in ipv6) {
      await _netsh([
        'interface',
        'ipv6',
        'set',
        'dnsservers',
        'name=${item.alias}',
        'source=dhcp',
      ]);
    }
    return true;
  }

  /// 接管系统 DNS；成功返回 true。
  Future<bool> apply() async {
    if (!takeoverEnabled) {
      return false;
    }
    if (!Platform.isWindows) {
      return false;
    }
    if (_applied) {
      return true;
    }
    if (!await _waitDnsPortReady()) {
      commonPrint.log('[SystemDns] 内核 DNS 端口未就绪，暂不接管系统 DNS');
      return false;
    }
    final snapshot = await capture();
    if (snapshot == null || snapshot.isEmpty) {
      commonPrint.log('[SystemDns] 没有可接管的网卡，跳过');
      return false;
    }
    await _applyFamily(4, snapshot.ipv4, _loopback);
    await _applyFamily(6, snapshot.ipv6, _loopbackIpv6);
    if (!await _verifyResolution()) {
      commonPrint.log('[SystemDns] 本机 DNS 解析校验失败，恢复原系统 DNS');
      _snapshot = snapshot;
      await restore(force: true);
      return false;
    }
    _snapshot = snapshot;
    _applied = true;
    commonPrint.log(
      '[SystemDns] 已接管系统 DNS（IPv4 ${snapshot.ipv4.length} 个网卡 → $_loopback，'
      'IPv6 ${snapshot.ipv6.length} 个网卡 → $_loopbackIpv6）',
    );
    return true;
  }

  Future<void> _applyFamily(
    int family,
    List<SystemDnsInterface> interfaces,
    String server,
  ) async {
    for (final item in interfaces) {
      await _netsh([
        'interface',
        'ipv$family',
        'set',
        'dnsservers',
        'name=${item.alias}',
        'static',
        server,
        'primary',
      ]);
    }
  }

  /// 恢复接管前的系统 DNS。
  ///
  /// 用 `source=dhcp` 恢复：本机原始 DNS 由 DHCP 下发；静态 DNS 的环境里
  /// 这样会把网卡切回 DHCP，需要用户自己再设置一次（可接受，因为只有
  /// 用户关闭「自动设置系统 DNS」才会走到这个分支之外）。
  ///
  /// [force] 用于「已写入但还没标记成功」的异常路径（解析校验失败时）。
  Future<void> restore({bool force = false}) async {
    final snapshot = _snapshot;
    if (!Platform.isWindows || snapshot == null || (!_applied && !force)) {
      return;
    }
    _applied = false;
    _snapshot = null;
    for (final item in snapshot.ipv4) {
      await _netsh([
        'interface',
        'ipv4',
        'set',
        'dnsservers',
        'name=${item.alias}',
        'source=dhcp',
      ]);
    }
    for (final item in snapshot.ipv6) {
      await _netsh([
        'interface',
        'ipv6',
        'set',
        'dnsservers',
        'name=${item.alias}',
        'source=dhcp',
      ]);
    }
    commonPrint.log('[SystemDns] 已恢复系统 DNS');
  }

  Future<bool> _waitDnsPortReady() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final socket = await Socket.connect(
          _loopback,
          53,
          timeout: const Duration(seconds: 1),
        );
        socket.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    return false;
  }

  Future<bool> _verifyResolution() async {
    // 用 .NET 的同步解析接口（走系统 DNS 栈）；切换 DNS 后有短暂缓存窗口，
    // 失败重试几次。
    const script =
        '\$ips = [System.Net.Dns]::GetHostAddresses('
        "'www.baidu.com'); if (\$ips) { \$ips[0].IPAddressToString }";
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final output = await _powershell(script);
        if (output.trim().isNotEmpty) {
          return true;
        }
      } catch (_) {
        // 解析失败时继续重试。
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    return false;
  }

  Future<ProcessResult> _netsh(List<String> args) async {
    try {
      final result = await Process.run('netsh', args, stdoutEncoding: utf8);
      if (result.exitCode != 0) {
        commonPrint.log(
          '[SystemDns] netsh ${args.join(' ')} 失败(${result.exitCode}): '
          '${(result.stdout as String).trim()}',
        );
      }
      return result;
    } catch (error) {
      commonPrint.log('[SystemDns] netsh 执行异常: $error');
      rethrow;
    }
  }

  Future<String> _powershell(String script) async {
    // Windows PowerShell 默认按系统 ANSI 输出，中文网卡名会让 UTF-8 解码失败
    // （FormatException: Missing extension byte），这里强制 UTF-8。
    const prefix =
        '[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
        '\$OutputEncoding=[Text.Encoding]::UTF8; ';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '$prefix$script',
    ], stdoutEncoding: utf8);
    return (result.stdout as String).trim();
  }
}
