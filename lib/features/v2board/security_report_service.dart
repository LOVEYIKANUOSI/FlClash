import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_store.dart';
import 'client.dart';
import 'device_fingerprint.dart';
import 'security_check.dart';

/// 设备环境画像采集 + 注册上报（对齐面板 client-api.md 第 3 节）。
///
/// 登录时经 register 携带 profile 全量上报；之后随心跳节流（每 N 次）
/// 重发 register 更新环境画像。仅上报、不阻断；失败静默并记录日志。
class SecurityReportService {
  SecurityReportService._();

  static final SecurityReportService instance = SecurityReportService._();

  static const int _reportEveryNBeats = 10;
  static const String _lastSnapshotKey = 'v2b_security_last_profile_snapshot';

  int _beatCounter = 0;

  /// 带环境画像注册设备，返回面板下发的设备数据
  /// （device_id / totp_secret / heartbeat_interval / active / domain_pool）。
  /// 失败返回 null。
  Future<Map<String, dynamic>?> registerWithProfile({
    bool skipIfUnchanged = false,
  }) async {
    final authStore = AuthStore();
    await authStore.init();
    final baseUrl = authStore.panelUrl;
    final authData = authStore.authData;
    if (authData == null || authData.isEmpty) {
      return null;
    }

    final fingerprint = await DeviceFingerprint.collect();
    commonPrint.log(
      '[Security] 指纹: mac=${fingerprint.mac} disk=${fingerprint.diskSerial} '
      'guid=${fingerprint.machineGuid}',
    );
    if (!fingerprint.isCollected || fingerprint.mac == '-') {
      commonPrint.log('[Security] 注册跳过：网卡码无效，无法注册设备');
      return null;
    }

    final profile = await SecurityCheck.collect(
      clientVersion: globalState.packageInfo.version,
    );
    commonPrint.log(
      '[Security] 画像采集完成: isVm=${profile.isVm} apps=${profile.appsCount}',
    );

    final snapshot = _buildSnapshot(fingerprint, profile);
    if (skipIfUnchanged && await _isUnchanged(snapshot)) {
      commonPrint.log('[Security] 画像与上次上报一致，跳过上传');
      return null;
    }

    try {
      final device = await v2BoardClient.registerDevice(
        baseUrl,
        authData,
        mac: fingerprint.mac,
        diskSerial: fingerprint.diskSerial,
        machineGuid: fingerprint.machineGuid,
        profile: profile.toJson(),
      );
      if (device == null) {
        commonPrint.log('[Security] 注册失败：后端未返回设备数据');
        return null;
      }
      await _saveSnapshot(snapshot);

      final deviceId = device['device_id']?.toString();
      final totpSecret = device['totp_secret']?.toString();
      final interval = device['heartbeat_interval'];
      if (deviceId != null &&
          deviceId.isNotEmpty &&
          totpSecret != null &&
          totpSecret.isNotEmpty) {
        await authStore.saveDevice(
          deviceId: deviceId,
          totpSecret: totpSecret,
          heartbeatIntervalSeconds: interval is int ? interval : null,
        );
      }
      final pool = (device['domain_pool'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      if (pool.isNotEmpty) {
        final active = (device['active'] ?? pool.first).toString();
        await authStore.saveDomains(activeDomain: active, domainPool: pool);
      }
      commonPrint.log('[Security] 注册成功: deviceId=$deviceId');
      return device;
    } catch (e) {
      commonPrint.log('[Security] 注册异常: $e', logLevel: LogLevel.warning);
      return null;
    }
  }

  /// 心跳节流触发环境画像重报。
  Future<void> onHeartbeat() async {
    _beatCounter++;
    if (_beatCounter % _reportEveryNBeats == 0) {
      await registerWithProfile(skipIfUnchanged: true);
    }
  }

  String _buildSnapshot(DeviceFingerprint fingerprint, SecurityReport profile) {
    return '${fingerprint.mac}|${fingerprint.diskSerial}'
        '|${fingerprint.machineGuid}|${jsonEncode(profile.toJson())}';
  }

  Future<bool> _isUnchanged(String snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_lastSnapshotKey) == snapshot;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveSnapshot(String snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastSnapshotKey, snapshot);
    } catch (_) {}
  }
}
