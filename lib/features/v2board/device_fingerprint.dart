import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';

/// 设备指纹：网卡 MAC / 系统盘序列号 / Windows MachineGuid。
///
/// 以网卡 MAC 为主标识（面板 DeviceService 的唯一键），其余作辅助校验；
/// 采集失败时字段返回 '-'，不阻塞主流程。
class DeviceFingerprint {
  final String mac;
  final String diskSerial;
  final String machineGuid;

  const DeviceFingerprint({
    required this.mac,
    required this.diskSerial,
    required this.machineGuid,
  });

  bool get isCollected =>
      mac != '-' || diskSerial != '-' || machineGuid != '-';

  static DeviceFingerprint? _cache;
  static Future<DeviceFingerprint>? _inflight;

  /// 带并发去重 + 结果缓存的采集入口（硬件标识长期不变）。
  static Future<DeviceFingerprint> collect() {
    final cached = _cache;
    if (cached != null && cached.isCollected) {
      return Future.value(cached);
    }
    final inflight = _inflight;
    if (inflight != null) {
      return inflight;
    }
    final future = _collectImpl();
    _inflight = future;
    return future.then((result) {
      if (result.isCollected) {
        _cache = result;
      }
      return result;
    }).whenComplete(() {
      _inflight = null;
    });
  }

  static Future<DeviceFingerprint> _collectImpl() async {
    if (Platform.isAndroid) {
      return _collectAndroid();
    }
    if (!Platform.isWindows) {
      return const DeviceFingerprint(
        mac: '-',
        diskSerial: '-',
        machineGuid: '-',
      );
    }
    try {
      const script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$guid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
$mac = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).MacAddress
$disk = (Get-CimInstance Win32_DiskDrive | Select-Object -First 1).SerialNumber
Write-Output ($guid + '|' + $mac + '|' + $disk)
''';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 45));
      final out = (result.stdout as String).trim();
      if (out.isEmpty) {
        commonPrint.log(
          '[Fingerprint] 脚本无输出 err=${result.stderr} code=${result.exitCode}',
          logLevel: LogLevel.warning,
        );
        return const DeviceFingerprint(
          mac: '-',
          diskSerial: '-',
          machineGuid: '-',
        );
      }
      final parts = out.split('|');
      return DeviceFingerprint(
        machineGuid: parts.isNotEmpty ? _clean(parts[0]) : '-',
        mac: parts.length > 1 ? _clean(parts[1]) : '-',
        diskSerial: parts.length > 2 ? _clean(parts[2]) : '-',
      );
    } catch (e) {
      commonPrint.log(
        '[Fingerprint] 采集异常: ${sanitizeV2BoardLog(e)}',
        logLevel: LogLevel.warning,
      );
      return const DeviceFingerprint(
        mac: '-',
        diskSerial: '-',
        machineGuid: '-',
      );
    }
  }

  static String _clean(String value) {
    final s = value.trim();
    return s.isEmpty ? '-' : s;
  }

  /// Android 端没有可用的网卡 MAC/磁盘序列号，用 ANDROID_ID 作为主标识
  /// （同一设备+同一签名密钥下稳定，卸载重装不变，Android 8+ 全版本可用）。
  static Future<DeviceFingerprint> _collectAndroid() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final androidId = info.id.trim().toUpperCase();
      if (androidId.isEmpty || androidId == 'UNKNOWN') {
        return const DeviceFingerprint(
          mac: '-',
          diskSerial: '-',
          machineGuid: '-',
        );
      }
      return DeviceFingerprint(
        mac: 'ANDROID-$androidId',
        diskSerial: androidId,
        machineGuid: androidId,
      );
    } catch (e) {
      commonPrint.log(
        '[Fingerprint] Android 采集异常: ${sanitizeV2BoardLog(e)}',
        logLevel: LogLevel.warning,
      );
      return const DeviceFingerprint(
        mac: '-',
        diskSerial: '-',
        machineGuid: '-',
      );
    }
  }
}
