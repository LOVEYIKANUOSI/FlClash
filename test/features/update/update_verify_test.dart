import 'package:fl_clash/features/update/update_verify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 这组数据由服务端同款 PHP `openssl_sign(..., OPENSSL_ALGO_SHA256)` 生成，
  // 用来验证 Dart 端 pointycastle 的验签与 PHP 的签名格式完全兼容。
  const payload =
      'dawn-update-v1\n'
      'windows-x64\n'
      '2026111901\n'
      '31457280\n'
      'a3f1c9d2e7b4a8f60c5d1e9b7a3f2c8d4e6b9a1f3c5d7e9b0a2c4e6f8b1d3a5c';
  const signature =
      'VnT614zyVhZDNu6YyCk8NRtOrGR2JOfGBVIVMWBe7AMNTkgTg1OMZLEEzn3dtaiL'
      'xOnLhugnxbp5ycls5YZGLdbG7XU9qgkhGabGtqg4rd2S9uls/ydJCb9cR4jYq1X/s'
      'surFyre8MjAxmCJJ/ri8nTvqCJIoZ9KrfK04Be6UjyhgrRNbvRe+yC9g1l115caok'
      'j2/LL1mTXhKxq0T2RZLmLnV5c0Gj55Q9OJvPImyZaeDG7IP6WMTnoKusFtdGVlRZ'
      'wr/Wb3T2/ihkv3noUTSkBbgGRahahiZmuKdg4awhqPPt1pnziNe69E8X77K+yqZ2q'
      '0mZF8LUcoEUMPp0xbNA==';

  test('public key is configured', () {
    expect(isUpdateSignatureConfigured, isTrue);
  });

  test('verifies a PHP openssl RSA-SHA256 signature', () {
    expect(
      verifyUpdateSignature(payload: payload, signature: signature),
      isTrue,
    );
  });

  test('rejects a tampered payload', () {
    expect(
      verifyUpdateSignature(payload: '$payload-tampered', signature: signature),
      isFalse,
    );
  });

  test('rejects a tampered signature', () {
    expect(
      verifyUpdateSignature(
        payload: payload,
        signature: signature.replaceFirst('VnT6', 'AAAA'),
      ),
      isFalse,
    );
  });

  test('rejects empty signature', () {
    expect(verifyUpdateSignature(payload: payload, signature: ''), isFalse);
  });
}
