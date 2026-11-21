import 'package:fl_clash/common/credential_cipher.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AuthStore 凭据落盘加密', () {
    test('save 后 token / authData 在 shared_preferences 里是密文', () async {
      final store = AuthStore();
      await store.init();
      await store.save(
        panelUrl: 'https://gettakeoff.cc',
        email: 'a@b.com',
        authData: 'jwt-auth-data-value',
        token: 'subscribe-token-value',
      );

      final prefs = await SharedPreferences.getInstance();
      final rawToken = prefs.getString('v2b_token');
      final rawAuth = prefs.getString('v2b_auth_data');
      expect(rawToken, isNotNull);
      expect(rawAuth, isNotNull);
      expect(CredentialCipher.isEncryptedField(rawToken), isTrue);
      expect(CredentialCipher.isEncryptedField(rawAuth), isTrue);
      expect(rawToken, isNot(contains('subscribe-token-value')));
      expect(rawAuth, isNot(contains('jwt-auth-data-value')));

      // 读接口仍是明文：业务层无感。
      expect(store.token, 'subscribe-token-value');
      expect(store.authData, 'jwt-auth-data-value');
      expect(store.hasSession, isTrue);
    });

    test('saveDevice 后设备 ID / TOTP 密钥在磁盘上是密文', () async {
      final store = AuthStore();
      await store.init();
      await store.saveDevice(
        deviceId: 'device-id-0123456789',
        totpSecret: 'JBSWY3DPEHPK3PXP',
        heartbeatIntervalSeconds: 60,
      );

      final prefs = await SharedPreferences.getInstance();
      final rawDevice = prefs.getString('v2b_device_id');
      final rawSecret = prefs.getString('v2b_totp_secret');
      expect(CredentialCipher.isEncryptedField(rawDevice), isTrue);
      expect(CredentialCipher.isEncryptedField(rawSecret), isTrue);
      expect(rawDevice, isNot(contains('device-id-0123456789')));
      expect(rawSecret, isNot(contains('JBSWY3DPEHPK3PXP')));

      expect(store.deviceId, 'device-id-0123456789');
      expect(store.totpSecret, 'JBSWY3DPEHPK3PXP');
      expect(store.heartbeatIntervalSeconds, 60);
    });

    test('旧版本明文值读取正常，并被异步迁移成密文', () async {
      SharedPreferences.setMockInitialValues({
        'v2b_token': 'legacy-plain-token',
        'v2b_device_id': 'legacy-device',
        'v2b_totp_secret': 'LEGACYTOTPSECRET',
      });
      final store = AuthStore();
      await store.init();

      // 首次读取：明文原样返回，业务可用。
      expect(store.token, 'legacy-plain-token');
      expect(store.deviceId, 'legacy-device');
      expect(store.totpSecret, 'LEGACYTOTPSECRET');

      // 迁移是 unawaited 的：让出事件循环后磁盘值应变成密文。
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(
        CredentialCipher.isEncryptedField(prefs.getString('v2b_token')),
        isTrue,
      );
      expect(store.token, 'legacy-plain-token');
    });

    test('clearSession 清掉密文，读接口返回 null', () async {
      final store = AuthStore();
      await store.init();
      await store.save(
        panelUrl: 'https://gettakeoff.cc',
        email: 'a@b.com',
        authData: 'jwt',
        token: 'token',
      );
      await store.clearSession();
      expect(store.authData, isNull);
      expect(store.token, isNull);
      expect(store.hasSession, isFalse);
    });

    test('换机器/损坏的密文读取返回 null（不会把密文当 token 用）', () async {
      const foreignField = '${CredentialCipher.fieldPrefix}bogus:bogus';
      SharedPreferences.setMockInitialValues({'v2b_token': foreignField});
      final store = AuthStore();
      await store.init();
      expect(store.token, isNull);
      expect(store.hasSession, isFalse);
    });
  });
}
