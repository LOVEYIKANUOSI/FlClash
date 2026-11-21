// 临时校验脚本：确认 CredentialCipher 的加解密往返正确、且换机器解不开。
// 用法：dart run tool/check_cipher.dart
import 'dart:io';

import 'package:fl_clash/common/credential_cipher.dart';

void main() {
  const plain = '{"email":"a@b.com","password":"p@ss:w0rd 中文"}';
  final encrypted = CredentialCipher.encrypt(plain);
  if (encrypted == null) {
    stdout.writeln('RESULT encrypt=null FAIL');
    exit(2);
  }
  final decrypted = CredentialCipher.decrypt(encrypted);
  final ok = decrypted == plain;
  stdout.writeln('RESULT encrypt_len=${encrypted.length} roundtrip=$ok');

  // 篡改一个字节必须解不开（GCM 认证）
  final tampered = encrypted.substring(0, encrypted.length - 2) +
      (encrypted.endsWith('AA') ? 'BB' : 'AA');
  final tamperedResult = CredentialCipher.decrypt(tampered);
  stdout.writeln('RESULT tampered_null=${tamperedResult == null}');

  // 每次加密 nonce 不同 → 密文不同
  final second = CredentialCipher.encrypt(plain);
  stdout.writeln('RESULT nonce_random=${second != encrypted}');

  if (!ok || tamperedResult != null || second == encrypted) {
    stdout.writeln('RESULT OVERALL FAIL');
    exit(1);
  }
  stdout.writeln('RESULT OVERALL PASS');
}
