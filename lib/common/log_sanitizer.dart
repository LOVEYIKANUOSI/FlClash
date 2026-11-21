/// V2Board 日志脱敏。
///
/// 两个直接的泄露面：
/// 1. 订阅链接带 `token` / `code` / `sign` / `expires` / `device_id`，而
///    `DioException.toString()` 会把完整请求 URL 打进日志；
/// 2. 设备上报日志里的 `mac=` / `disk=` / `guid=` / `deviceId=`。
///
/// 这里统一在打印前打码，只保留「能定位问题」的部分（域名、失败原因）。
library;

/// URL / 文本里的秘密 query 参数：`?token=..&code=..&sign=..`。
final _secretQueryPattern = RegExp(
  '([?&](?:token|code|sign|expires|device_id|auth_data)=)[^&\\s"\'<>]+',
  caseSensitive: false,
);

/// JSON / 错误体里直接出现的 `subscribe_url` 字段值。
final _subscribeUrlPattern = RegExp(
  '(subscribe_url["\']?\\s*[:=]\\s*["\']?)([^"\'\\s,}]+)',
  caseSensitive: false,
);

/// 设备指纹字段（`mac=..`、`disk=..`、`guid=..`、`deviceId=..`）。
final _fingerprintPattern = RegExp(
  '\\b(mac|disk|guid|machineGuid|deviceId)\\s*[=:]\\s*([^\\s,}]+)',
  caseSensitive: false,
);

/// 把异常 / 日志文本里的凭据与设备指纹打码。
String sanitizeV2BoardLog(Object? error) {
  if (error == null) {
    return '';
  }
  var text = error.toString();
  text = text.replaceAllMapped(_secretQueryPattern, (m) => '${m[1]}***');
  text = text.replaceAllMapped(_subscribeUrlPattern, (m) => '${m[1]}***');
  text = text.replaceAllMapped(
    _fingerprintPattern,
    (m) => '${m[1]}=${maskSecret(m[2] ?? '')}',
  );
  return text;
}

/// 单个敏感值只保留头尾少量字符：日志里还能区分是哪个设备/哪台机器，
/// 但拿不到完整值。长度 ≤ 8 直接全遮。
String maskSecret(String value) {
  if (value.isEmpty) {
    return value;
  }
  if (value.length <= 8) {
    return '***';
  }
  final head = value.substring(0, 4);
  final tail = value.substring(value.length - 2);
  return '$head***$tail';
}
