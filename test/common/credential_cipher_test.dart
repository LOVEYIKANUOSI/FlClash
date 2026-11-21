import 'dart:convert';

import 'package:fl_clash/common/credential_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CredentialCipher 字段级加解密', () {
    test('encryptField / decryptField 往返', () {
      const plain = 'device-1234567890abcdef';
      final encrypted = CredentialCipher.encryptField(plain);
      expect(encrypted, startsWith(CredentialCipher.fieldPrefix));
      expect(encrypted, isNot(plain));
      expect(CredentialCipher.decryptField(encrypted), plain);
    });

    test('中文 / 符号 / JSON 都能往返', () {
      const plain = '{"email":"a@b.com","password":"p@ss:w0rd 中文"}';
      final encrypted = CredentialCipher.encryptField(plain);
      expect(CredentialCipher.decryptField(encrypted), plain);
    });

    test('旧版本明文（无前缀）原样返回，便于平滑升级', () {
      const legacy = 'plain-legacy-token';
      expect(CredentialCipher.isEncryptedField(legacy), isFalse);
      expect(CredentialCipher.decryptField(legacy), legacy);
    });

    test('空值原样返回，不加密也不报错', () {
      expect(CredentialCipher.encryptField(''), '');
      expect(CredentialCipher.decryptField(''), '');
      expect(CredentialCipher.decryptField(null), isNull);
    });

    test('密文被篡改后解不开（返回 null）', () {
      final encrypted = CredentialCipher.encryptField('secret-value-123');
      final tampered = '${encrypted.substring(0, encrypted.length - 2)}AA';
      expect(CredentialCipher.decryptField(tampered), isNull);
    });

    test('同一明文每次加密结果不同（随机 nonce）', () {
      const plain = 'same-plain-text-abcdef';
      final a = CredentialCipher.encryptField(plain);
      final b = CredentialCipher.encryptField(plain);
      expect(a, isNot(b));
      expect(CredentialCipher.decryptField(a), plain);
      expect(CredentialCipher.decryptField(b), plain);
    });

    test('isEncryptedField 只认带前缀的值', () {
      final encrypted = CredentialCipher.encryptField('x' * 24);
      expect(CredentialCipher.isEncryptedField(encrypted), isTrue);
      expect(CredentialCipher.isEncryptedField('plain'), isFalse);
      expect(CredentialCipher.isEncryptedField(''), isFalse);
      expect(CredentialCipher.isEncryptedField(null), isFalse);
    });

    test('字段级密文依赖本机环境指纹（跨 key 不可解）', () {
      // 用「整体 encrypt」模拟别的机器/别的 key 产生的载荷：前缀对但解不开。
      final foreign =
          '${CredentialCipher.fieldPrefix}${base64Encode(List<int>.filled(16, 7))}:'
          '${base64Encode(List<int>.filled(32, 9))}';
      expect(CredentialCipher.decryptField(foreign), isNull);
    });
  });
}
