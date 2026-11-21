import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'package:fl_clash/common/common.dart';

/// 专属订阅（app=flclash）加密载荷的客户端解密。
///
/// 协议见 `docs/subscribe-encryption.md`：
/// - 服务端 `enc=1` 时返回 JSON：`{v, alg, kid, did, exp, blob}`
/// - `blob` = base64url(nonce[12] || ciphertext || tag[16])
/// - 密钥 `HKDF-SHA256(ikm=master_key, salt=utf8(device_id), info="flclash-sub-v1", len=32)`
/// - AES-256-GCM，`did` = sha256(device_id) 前 8 位 hex，用来防串号
///
/// 主密钥与服务端 `config('v2board.subscribe_enc_key')` 必须完全一致；
/// 这里拆成多段并在运行时拼接，避免明文常量被一眼 grep 出来。
class SubscribeCipher {
  SubscribeCipher._();

  static final SubscribeCipher instance = SubscribeCipher._();

  /// 主密钥 hex（生产 `subscribe_enc_key`，keyid=k1）。
  ///
  /// 出于安全考虑**不再硬编码到仓库**：构建时通过
  /// `--dart-define=SUBSCRIBE_ENC_KEY=<64 位 hex>` 注入；未注入时
  /// 专属订阅加密不可用（回退为明文拉取，见 `decode`）。
  static const String _masterHex = String.fromEnvironment(
    'SUBSCRIBE_ENC_KEY',
  );

  /// 是否已注入主密钥（64 位 hex）。
  static bool get isConfigured => _masterHex.length == 64;

  static const String _info = 'flclash-sub-v1';
  static const int _nonceLength = 12;
  static const int _tagLength = 16;

  Uint8List? _masterCache;

  Uint8List get _master {
    final cached = _masterCache;
    if (cached != null) return cached;
    final bytes = _hexToBytes(_masterHex);
    _masterCache = bytes;
    return bytes;
  }

  /// 响应体是否是加密载荷（JSON 且 alg=A256GCM）。
  static bool looksEncrypted(Uint8List? data) {
    if (data == null || data.isEmpty) return false;
    if (data[0] != 0x7b) return false; // '{'
    try {
      final decoded = jsonDecode(utf8.decode(data, allowMalformed: true));
      return decoded is Map<String, dynamic> &&
          decoded['alg'] == 'A256GCM' &&
          decoded['blob'] is String;
    } catch (_) {
      return false;
    }
  }

  /// 解密；失败返回 null（调用方决定报错还是回退）。
  Uint8List? decode(Uint8List data, String deviceId) {
    if (!isConfigured) {
      commonPrint.log(
        '[SubscribeCipher] 未注入 SUBSCRIBE_ENC_KEY，跳过专属订阅解密',
      );
      return null;
    }
    if (deviceId.isEmpty) {
      commonPrint.log('[SubscribeCipher] 解密失败：device_id 为空');
      return null;
    }
    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map<String, dynamic>) return null;
      payload = decoded;
    } catch (e) {
      commonPrint.log('[SubscribeCipher] 载荷不是合法 JSON: $e');
      return null;
    }
    if (payload['v'] != 1 || payload['alg'] != 'A256GCM') {
      commonPrint.log(
        '[SubscribeCipher] 不支持的加密协议 v=${payload['v']} alg=${payload['alg']}',
      );
      return null;
    }
    final expectedDid = sha256
        .convert(utf8.encode(deviceId))
        .toString()
        .substring(0, 8);
    final did = payload['did'];
    if (did is String && did.isNotEmpty && did != expectedDid) {
      commonPrint.log(
        '[SubscribeCipher] 密文与设备不匹配 did=$did expect=$expectedDid',
      );
      return null;
    }
    final blob = payload['blob'];
    if (blob is! String) return null;

    final Uint8List raw;
    try {
      raw = Uint8List.fromList(base64Url.decode(base64Url.normalize(blob)));
    } catch (e) {
      commonPrint.log('[SubscribeCipher] blob base64url 解码失败: $e');
      return null;
    }
    if (raw.length < _nonceLength + _tagLength) {
      commonPrint.log('[SubscribeCipher] blob 长度不足: ${raw.length}');
      return null;
    }

    final key = _hkdfSha256(
      _master,
      Uint8List.fromList(utf8.encode(deviceId)),
      utf8.encode(_info),
      32,
    );
    final nonce = Uint8List.sublistView(raw, 0, _nonceLength);
    final body = Uint8List.sublistView(raw, _nonceLength);

    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
        );
      final clear = cipher.process(body);
      commonPrint.log('[SubscribeCipher] 专属订阅解密成功 (${clear.length} bytes)');
      return Uint8List.fromList(clear);
    } catch (e) {
      commonPrint.log('[SubscribeCipher] AES-GCM 解密失败: $e');
      return null;
    }
  }

  static Uint8List _hkdfSha256(
    Uint8List ikm,
    Uint8List salt,
    List<int> info,
    int length,
  ) {
    // HKDF-Extract
    final prk = Hmac(sha256, salt).convert(ikm).bytes;
    // HKDF-Expand
    final out = BytesBuilder();
    var t = <int>[];
    var counter = 1;
    while (out.length < length) {
      t = Hmac(sha256, prk).convert([...t, ...info, counter]).bytes;
      out.add(t);
      counter++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
