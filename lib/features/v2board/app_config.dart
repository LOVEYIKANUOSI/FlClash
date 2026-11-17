/// Dawn 客户端与 V2Board 面板对接的统一配置。
///
/// 所有端点、默认域名、心跳/探测/TOTP 参数集中在这里，方便后续调整。
class AppConfig {
  AppConfig._();

  /// 默认面板地址（生产公网入口，必须带 https scheme）。
  static const defaultPanelUrl = 'https://n415fgd.952769.xyz';

  /// 面板 API 端点（与管理端 ClientController / UserDeviceController 对齐）。
  static const loginPath = '/api/v1/passport/auth/login';
  static const checkLoginPath = '/api/v1/user/checkLogin';
  static const deviceRegisterPath = '/api/v1/user/device/register';
  static const appSubscribePath = '/api/v1/user/appSubscribe';
  static const heartbeatPath = '/api/v1/user/heartbeat';
  static const reportDomainPath = '/api/v1/user/reportDomain';

  /// 订阅入口的默认路径（仅作兜底展示）。
  ///
  /// 生产面板的 `subscribe_path` 已随机化，实际订阅地址必须用面板下发的
  /// `subscribe_url`（`/api/v1/user/getSubscribe` 返回），不能自己拼。
  static const defaultSubscribePath = '/api/v1/client/subscribe';

  /// 设备签名 payload 里的 path 必须是这个**字面量**：
  /// 面板 `ClientController::verifyAppSubscribe()` 写死按它验签，
  /// 与随机化的 `subscribe_path` 无关。
  static const signPayloadPath = '/api/v1/client/subscribe';

  /// 订阅/API 请求里的专属客户端标记，面板据此走 TOTP + 签名校验。
  static const appMarker = 'flclash';

  /// 心跳间隔（面板可通过 register/heartbeat 下发覆盖）。
  static const defaultHeartbeatInterval = Duration(seconds: 60);

  /// 域名探测参数。
  static const probeInterval = Duration(minutes: 1);
  static const probeTimeout = Duration(seconds: 5);
  static const probeFailThreshold = 3;
  static const probeSampleCount = 2;

  /// TOTP 动态密码周期（RFC 6238）。
  static const totpPeriod = Duration(seconds: 30);

  /// 把用户输入的面板地址规范成「带 scheme、无尾斜杠」的形式。
  ///
  /// 参考实现直接用 `isUrl` 校验，用户只填域名时直接登录失败；
  /// 这里缺省补 https://，只要 host 非空就放行。
  static String normalizeUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      return value;
    }
    if (!value.contains('://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      return raw.trim();
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 域名（可能不带 scheme）规范成带 scheme 的 origin。
  static String normalizeDomain(String domain) {
    final value = domain.trim();
    if (value.isEmpty) {
      return value;
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return normalizeUrl(value);
    }
    return 'https://$value';
  }

  /// 判断面板下发的域名能不能真的拿来做 API 地址。
  ///
  /// 面板 `client_default_domain` / `CdnDomain(kind=client)` 没配置时，会下发
  /// 占位符 `client.example.invalid`（见 config/v2board.php 的默认值）。
  /// 客户端如果拿它当 active 域名，后续 checkLogin/心跳/getSubscribe 全部 DNS 失败。
  static bool isUsableDomain(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      return false;
    }
    final host = Uri.tryParse(normalizeDomain(value))?.host.toLowerCase() ?? '';
    if (host.isEmpty || !host.contains('.')) {
      return false;
    }
    const reservedSuffixes = ['.invalid', '.example', '.test', '.localhost'];
    for (final suffix in reservedSuffixes) {
      if (host.endsWith(suffix)) {
        return false;
      }
    }
    const reservedHosts = [
      'example.com',
      'example.org',
      'example.net',
      'localhost',
    ];
    for (final reserved in reservedHosts) {
      if (host == reserved || host.endsWith('.$reserved')) {
        return false;
      }
    }
    return true;
  }
}
