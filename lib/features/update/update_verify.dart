import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

/// 更新包签名公钥（RSA-2048，PKCS#1 v1.5 + SHA-256）。
///
/// 私钥只在发布机/服务端，用来签 `UpdateManifest.signaturePayload`；
/// 客户端只内嵌公钥。公钥为空时退化为「仅 sha256 + HTTPS」，并在日志里明确
/// 警告——服务端 `client:update:keygen` 产出密钥后必须把模数填到这里。
const _publicKeyModulusHex =
    '93659f0670f6c8d36f26bd08ab80ac81e81dde33ae9c2ab5d556045217e10dd9'
    'f6420eeeefed93b848ac6bebf593a77a95f9b2fc9442e4c3e1909beb0c686e19'
    '903f3d29a2dcf54b48312f3a05679733630cbe3a0b0506b0832d5e11b8010cec'
    '4c69ac5d2e678a3d3ddc9131495d0fabe82f5dbf176dfe909cd86519c626f2e7'
    'acdb8aa58ce18e8e691425058423635806257d875582c4402d95e401586d7901'
    '6ff4ed65399622bff7be023f6f813e949f45cc2ffdc88f32ac02634ed218cb75'
    'b82784ccb668573451bec97f5601c28d384046628f4732cc04e4d4a9eb7e08e7'
    'e757b402245a0742ead704c47eb8c1ab84595a30f760167aa7c344e1dc1d7caf';

/// RSA 公钥指数，固定 65537。
const _publicKeyExponentHex = '010001';

/// SHA-256 的 DER 摘要标识（RFC 8017 / PKCS#1 v1.5）。
const _sha256DigestIdentifierHex = '0609608648016503040201';

/// 公钥是否已配置。
bool get isUpdateSignatureConfigured => _publicKeyModulusHex.isNotEmpty;

/// 校验 [payload] 的 RSA-SHA256 签名。
///
/// 公钥未配置时返回 true（只靠 sha256），并在日志里打一次警告。
bool verifyUpdateSignature({
  required String payload,
  required String signature,
}) {
  if (!isUpdateSignatureConfigured) {
    commonPrint.log(
      'Update signature skipped: public key not configured',
      logLevel: LogLevel.warning,
    );
    return true;
  }
  if (signature.isEmpty) {
    return false;
  }
  try {
    final signer = RSASigner(SHA256Digest(), _sha256DigestIdentifierHex);
    signer.init(
      false,
      PublicKeyParameter<RSAPublicKey>(
        RSAPublicKey(
          BigInt.parse(_publicKeyModulusHex, radix: 16),
          BigInt.parse(_publicKeyExponentHex, radix: 16),
        ),
      ),
    );
    return signer.verifySignature(
      Uint8List.fromList(utf8.encode(payload)),
      RSASignature(base64Decode(signature)),
    );
  } catch (error) {
    commonPrint.log(
      'Update signature verify failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    return false;
  }
}
