import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 自动登录凭据的本地加密（AES-256-GCM + PBKDF2 派生密钥）。
///
/// 为什么不用 flutter_secure_storage：它的 Windows 实现依赖 ATL（`atlstr.h`），
/// 本项目用 MinGW 工具链编译不了；改用纯 Dart 实现后 Windows / Android 同一套代码。
///
/// 密钥**不落盘**：由本机环境指纹经 PBKDF2-HMAC-SHA256 派生。
/// 因此把 `shared_preferences.json` 拷到别的机器或别的用户下是解不开的；
/// 同一台机器同一用户仍能解 —— 本地加密只能做到这个程度，目的是让密码
/// 不以明文躺在配置文件里，而不是对抗本机提权。
class CredentialCipher {
  CredentialCipher._();

  static const _saltText = 'dawn.v2board.auto-login.v1';
  static const _iterations = 20000;
  static const _keyLength = 32;
  static const _nonceLength = 12;
  static const _tagBits = 128;

  static Uint8List? _cachedKey;

  /// 环境指纹只取跨版本稳定的项：用户名 / 机器名 / 用户目录。
  ///
  /// 特意**不**加入 `Platform.resolvedExecutable`：绿色版用户可能把 exe 换个目录
  /// 或换个名字运行，那样会导致已保存的密码解不开、又要重新登录一次。
  static Uint8List get _machineSeed {
    final env = Platform.environment;
    final parts = <String>[
      Platform.operatingSystem,
      env['COMPUTERNAME'] ?? '',
      env['USERNAME'] ?? env['USER'] ?? '',
      env['USERPROFILE'] ?? env['HOME'] ?? '',
    ];
    return Uint8List.fromList(utf8.encode(parts.join('|')));
  }

  static Uint8List _key() {
    final cached = _cachedKey;
    if (cached != null) {
      return cached;
    }
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(
        Pbkdf2Parameters(
          Uint8List.fromList(utf8.encode(_saltText)),
          _iterations,
          _keyLength,
        ),
      );
    final key = derivator.process(_machineSeed);
    _cachedKey = key;
    return key;
  }

  /// 加密，返回 `base64(nonce):base64(ciphertext+tag)`；失败返回 null。
  static String? encrypt(String plainText) {
    try {
      final random = Random.secure();
      final nonce = Uint8List.fromList(
        List<int>.generate(_nonceLength, (_) => random.nextInt(256)),
      );
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(_key()),
            _tagBits,
            nonce,
            Uint8List(0),
          ),
        );
      final encrypted = cipher.process(
        Uint8List.fromList(utf8.encode(plainText)),
      );
      return '${base64Encode(nonce)}:${base64Encode(encrypted)}';
    } catch (_) {
      return null;
    }
  }

  /// 解密 [encrypt] 的输出；密文损坏/换了机器都返回 null。
  static String? decrypt(String payload) {
    try {
      final separator = payload.indexOf(':');
      if (separator <= 0) {
        return null;
      }
      final nonce = base64Decode(payload.substring(0, separator));
      final data = base64Decode(payload.substring(separator + 1));
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(_key()),
            _tagBits,
            nonce,
            Uint8List(0),
          ),
        );
      return utf8.decode(cipher.process(data));
    } catch (_) {
      return null;
    }
  }

  /// 落盘字段前缀：带此前缀的值是密文，没有前缀的按旧版本明文兼容。
  ///
  /// 用于 shared_preferences / sqlite 这类「字段级」加密（token、设备 ID、
  /// TOTP 密钥、订阅链接），与 [encrypt] 的「整体载荷」用法区分开。
  static const fieldPrefix = 'enc:v1:';

  /// 加密一个落盘字段；空串原样返回（空值没有加密意义）。
  ///
  /// 加密失败（几乎不可能）时退化为明文，宁可多一次明文也不丢用户数据；
  /// 解密侧会按无前缀=明文兼容。
  static String encryptField(String plainText) {
    if (plainText.isEmpty) {
      return plainText;
    }
    final cipherText = encrypt(plainText);
    if (cipherText == null || cipherText.isEmpty) {
      return plainText;
    }
    return '$fieldPrefix$cipherText';
  }

  /// 解密一个落盘字段。
  ///
  /// - 没有 [fieldPrefix] 前缀 → 视为旧版本明文，原样返回（便于平滑升级）；
  /// - 有前缀但解不开（换了机器/换了用户/数据损坏）→ 返回 null。
  static String? decryptField(String? value) {
    if (value == null || value.isEmpty) {
      return value;
    }
    if (!value.startsWith(fieldPrefix)) {
      return value;
    }
    return decrypt(value.substring(fieldPrefix.length));
  }

  /// 值是否是本机加密后的密文（用于旧数据迁移判断）。
  static bool isEncryptedField(String? value) {
    return value != null && value.startsWith(fieldPrefix);
  }
}
