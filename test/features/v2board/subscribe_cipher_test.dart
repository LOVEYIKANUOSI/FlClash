import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/features/v2board/subscribe_cipher.dart';

void main() {
  final fixtureFile = File(
    'test/features/v2board/subscribe_cipher_fixture.json',
  );
  final plainFile = File(
    'test/features/v2board/subscribe_cipher_fixture_plain.txt',
  );
  final deviceFile = File(
    'test/features/v2board/subscribe_cipher_fixture_device.txt',
  );

  late Uint8List payloadBytes;
  late String expectedPlain;
  late String deviceId;

  setUpAll(() {
    payloadBytes = Uint8List.fromList(fixtureFile.readAsBytesSync());
    expectedPlain = utf8.decode(
      base64Decode(plainFile.readAsStringSync().trim()),
    );
    deviceId = deviceFile.readAsStringSync().trim();
  });

  group('SubscribeCipher', () {
    test('looksEncrypted recognizes the real payload', () {
      expect(SubscribeCipher.looksEncrypted(payloadBytes), isTrue);
    });

    test('looksEncrypted rejects plain YAML', () {
      final yaml = Uint8List.fromList(utf8.encode('mixed-port: 7890\n'));
      expect(SubscribeCipher.looksEncrypted(yaml), isFalse);
    });

    test(
      'decodes the PHP-generated payload',
      () {
        final clear = SubscribeCipher.instance.decode(payloadBytes, deviceId);
        expect(clear, isNotNull);
        expect(utf8.decode(clear!), expectedPlain);
        expect(utf8.decode(clear), startsWith('mixed-port: 7890'));
      },
      skip: SubscribeCipher.isConfigured
          ? null
          : '需要 --dart-define=SUBSCRIBE_ENC_KEY=<64位hex> 才能解密 fixture',
    );

    test('rejects a payload issued for another device', () {
      final clear = SubscribeCipher.instance.decode(
        payloadBytes,
        'another-device-0000',
      );
      expect(clear, isNull);
    });

    test('rejects empty device id', () {
      expect(SubscribeCipher.instance.decode(payloadBytes, ''), isNull);
    });

    test(
      'rejects a tampered blob',
      () {
        final json =
            jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;
        final blob = json['blob'] as String;
        final bytes = base64Url.decode(base64Url.normalize(blob));
        bytes[bytes.length - 1] ^= 0xff;
        json['blob'] = base64Url.encode(bytes).replaceAll('=', '');
        final tampered = Uint8List.fromList(utf8.encode(jsonEncode(json)));
        expect(SubscribeCipher.instance.decode(tampered, deviceId), isNull);
      },
      skip: SubscribeCipher.isConfigured
          ? null
          : '需要 --dart-define=SUBSCRIBE_ENC_KEY=<64位hex> 才能解密 fixture',
    );
  });
}
