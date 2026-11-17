import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'app_config.dart';

/// RFC 6238 TOTP（HMAC-SHA1，30s，6 位）+ 设备订阅签名。
///
/// 与面板 `TotpService::verify` / `ClientController::verifyAppSubscribe` 对齐：
/// - code = TOTP(totp_secret, 当前 30s 窗口)
/// - sign = hex(HMAC-SHA256(totp_secret, "$deviceId|$expires|/api/v1/client/subscribe"))
class Totp {
  Totp._();

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// 生成当前 30 秒窗口的 6 位动态密码。
  static String generate(String secret, {DateTime? time}) {
    final key = _base32Decode(secret);
    final unixSeconds =
        (time ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final counter = unixSeconds ~/ AppConfig.totpPeriod.inSeconds;
    final hmac = Hmac(sha1, key).convert(_bigEndian8(counter)).bytes;
    final offset = hmac[hmac.length - 1] & 0x0f;
    final binary = ((hmac[offset] & 0x7f) << 24) |
        ((hmac[offset + 1] & 0xff) << 16) |
        ((hmac[offset + 2] & 0xff) << 8) |
        (hmac[offset + 3] & 0xff);
    final otp = binary % 1000000;
    return otp.toString().padLeft(6, '0');
  }

  /// 设备订阅签名：HMAC-SHA256(secret, payload)，返回 hex。
  static String sign(String secret, String payload) {
    return Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode(payload))
        .toString();
  }

  /// 在面板下发的订阅链接上追加 TOTP 时效签名，得到「专属订阅」。
  ///
  /// 注意两点：
  /// - 请求地址（scheme/host/随机化的 path/token）必须原样沿用面板给的
  ///   [subscribeUrl]，不能自己拼 `/api/v1/client/subscribe`；
  /// - 签名 payload 里的 path 反而是字面量 [AppConfig.signPayloadPath]。
  static String buildSignedSubscribeUrl({
    required String subscribeUrl,
    required String deviceId,
    required String totpSecret,
    Duration ttl = const Duration(minutes: 2),
  }) {
    final expires = DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
    final code = generate(totpSecret);
    final payload = '$deviceId|$expires|${AppConfig.signPayloadPath}';
    final signature = sign(totpSecret, payload);
    final uri = Uri.parse(subscribeUrl.trim());
    final query = Map<String, String>.from(uri.queryParameters);
    query.addAll({
      'flag': 'meta',
      'app': AppConfig.appMarker,
      'device_id': deviceId,
      'code': code,
      'expires': '$expires',
      'sign': signature,
    });
    return uri.replace(queryParameters: query).toString();
  }

  static Uint8List _bigEndian8(int value) {
    final bytes = Uint8List(8);
    var v = value;
    for (var i = 7; i >= 0; i--) {
      bytes[i] = v & 0xff;
      v >>= 8;
    }
    return bytes;
  }

  static Uint8List _base32Decode(String input) {
    final b32 = input.toUpperCase().replaceAll('=', '');
    final output = <int>[];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < b32.length; i++) {
      final value = _alphabet.indexOf(b32[i]);
      if (value < 0) {
        continue;
      }
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        output.add((buffer >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return Uint8List.fromList(output);
  }
}
