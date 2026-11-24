import 'package:fl_clash/enum/enum.dart';

/// 防 DNS 泄露的默认 DNS 配置（2026-11-24）。
///
/// 背景：FlClash 之前把 DNS 交给机场订阅里的明文 DNS（`223.5.5.5` 之类），
/// mihomo 为匹配规则（如 `GEOIP,CN,DIRECT`）会把域名交给它们做明文查询，
/// 在 dnsleaktest 一类的检测里就表现为「DNS 泄露」。V2rayN 的 sing-box 配置里
/// 有 `detour: proxy` 的远程 DoH，查询经代理服务器发出，所以不泄露。
///
/// 这里在 profile 没有提供**加密 DNS**时注入等价配置：
/// - 国内域名：国内 DoH（查询加密，本地网络看不到明文）；
/// - 国外域名：远程 DoH + `respect-rules: true`（查询遵守规则走代理，本地网络不可见）；
/// - 节点服务器域名：用国内公共 DNS 引导解析（`proxy-server-nameserver`）。
///
/// 注意：Dart 侧拿不到 profile 的 `proxy-groups`（内核 `getProfileBase` 会把
/// proxies/proxy-groups/rules 这些 bulk section 留在内核里），所以不能用
/// `https://1.1.1.1/dns-query#PROXY` 这种写法绑定代理组；改由
/// `respect-rules: true` 让 DNS 查询跟随规则（主流量走代理）出站。
const _cnDohServers = <String>[
  'https://doh.pub/dns-query',
  'https://dns.alidns.com/dns-query',
];

/// 远程 DoH 用 IP 直连，避免引导阶段再解析域名（也避免被污染）。
const _remoteDohServers = <String>[
  'https://1.1.1.1/dns-query',
  'https://8.8.8.8/dns-query',
];

const _bootstrapServers = <String>['223.5.5.5', '119.29.29.29'];

/// 这些键被用户显式覆盖时，说明用户自己接管了 DNS 行为，不再注入默认值。
const _protectionKeys = <DnsOverrideKey>{
  DnsOverrideKey.nameserver,
  DnsOverrideKey.fallback,
  DnsOverrideKey.nameserverPolicy,
};

/// DNS 查询是否已经加密：`https://`(DoH)、`tls://`(DoT)、`quic://`/`h3://`(DoQ)。
bool isEncryptedDnsServer(Object? server) {
  if (server is! String) {
    return false;
  }
  final value = server.trim().toLowerCase();
  return value.startsWith('https://') ||
      value.startsWith('tls://') ||
      value.startsWith('quic://') ||
      value.startsWith('h3://');
}

/// 给 DNS 段注入防泄露默认值；返回新 Map，不修改入参。
///
/// 以下情况直接原样返回（尊重用户与机场配置）：
/// - 全局关闭了该保护；
/// - 用户显式覆盖了 `nameserver`/`fallback`/`nameserver-policy`；
/// - profile 已经提供**加密** DNS（DoH/DoT/DoQ）。
///
/// 只有明文 DNS（`223.5.5.5`、`system://` 等）或空配置才会被替换。
Map<String, dynamic> applyDnsLeakProtection({
  required Map<String, dynamic> dns,
  required Set<DnsOverrideKey> overriddenKeys,
  bool enabled = true,
}) {
  if (!enabled) {
    return dns;
  }
  if (_protectionKeys.any(overriddenKeys.contains)) {
    return dns;
  }
  final existingNameserver = dns['nameserver'];
  if (existingNameserver is List &&
      existingNameserver.any(isEncryptedDnsServer)) {
    return dns;
  }
  final result = Map<String, dynamic>.from(dns);
  result['enable'] = true;
  result['enhanced-mode'] = 'fake-ip';
  // DNS 查询遵守路由规则：国外 DoH 会经代理发出，而不是直连本地网络。
  result['respect-rules'] = true;
  result['default-nameserver'] = _bootstrapServers;
  result['nameserver'] = _cnDohServers;
  result['fallback'] = _remoteDohServers;
  result['fallback-filter'] = {
    'geoip': true,
    'geoip-code': 'CN',
    'ipcidr': ['240.0.0.0/4'],
  };
  result['proxy-server-nameserver'] = _bootstrapServers;
  return result;
}
