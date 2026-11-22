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
    if (Platform.isLinux) {
      return _collectLinux();
    }
    if (Platform.isMacOS) {
      return _collectMacos();
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

  /// Linux（H-10）：`/etc/machine-id` 作 machineGuid，物理网卡 MAC 作主标识，
  /// 磁盘序列号从 sysfs/DMI 读取。
  static Future<DeviceFingerprint> _collectLinux() async {
    try {
      final machineId = await _readFirstLine([
        '/etc/machine-id',
        '/var/lib/dbus/machine-id',
      ]);
      final mac = await _readLinuxMac();
      final diskSerial = await _readLinuxDiskSerial();
      return DeviceFingerprint(
        mac: _clean(mac ?? '-'),
        diskSerial: _clean(diskSerial ?? '-'),
        machineGuid: _clean(machineId ?? '-'),
      );
    } catch (e) {
      commonPrint.log(
        '[Fingerprint] Linux 采集异常: ${sanitizeV2BoardLog(e)}',
        logLevel: LogLevel.warning,
      );
      return const DeviceFingerprint(
        mac: '-',
        diskSerial: '-',
        machineGuid: '-',
      );
    }
  }

  /// macOS（H-10）：`IoPlatformUUID` 作 machineGuid，`en0` 的 MAC 作主标识，
  /// `IoPlatformSerialNumber` 作磁盘序列号。
  static Future<DeviceFingerprint> _collectMacos() async {
    try {
      final result = await Process.run(
        'ioreg',
        ['-rd1', '-c', 'IOPlatformExpertDevice'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      final text = result.stdout as String;
      final uuid = RegExp(
        r'"IOPlatformUUID"\s*=\s*"([^"]+)"',
      ).firstMatch(text)?.group(1);
      final serial = RegExp(
        r'"IOPlatformSerialNumber"\s*=\s*"([^"]+)"',
      ).firstMatch(text)?.group(1);
      final mac = await _readMacosMac();
      return DeviceFingerprint(
        mac: _clean(mac ?? '-'),
        diskSerial: _clean(serial ?? '-'),
        machineGuid: _clean(uuid ?? '-'),
      );
    } catch (e) {
      commonPrint.log(
        '[Fingerprint] macOS 采集异常: ${sanitizeV2BoardLog(e)}',
        logLevel: LogLevel.warning,
      );
      return const DeviceFingerprint(
        mac: '-',
        diskSerial: '-',
        machineGuid: '-',
      );
    }
  }

  static Future<String?> _readFirstLine(List<String> paths) async {
    for (final path in paths) {
      try {
        final content = await File(path).readAsString();
        final first = content.trim().split('\n').first.trim();
        if (first.isNotEmpty) {
          return first;
        }
      } catch (_) {
        // 文件不存在或无权限：继续试下一个。
      }
    }
    return null;
  }

  /// 取第一块物理网卡 MAC；过滤 loopback/veth/docker/bridge/tun 等虚拟网卡。
  static Future<String?> _readLinuxMac() async {
    try {
      final entries = Directory('/sys/class/net').listSync();
      for (final entry in entries) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (_isVirtualInterface(name)) {
          continue;
        }
        final address = await File('${entry.path}/address').readAsString();
        final mac = address.trim().toLowerCase();
        if (_isUsableMac(mac)) {
          return mac.toUpperCase();
        }
      }
    } catch (_) {
      // 无 sysfs（容器/精简系统）：返回 null 由调用方降级。
    }
    return null;
  }

  static Future<String?> _readLinuxDiskSerial() async {
    final candidates = <String>['/sys/class/dmi/id/product_serial'];
    try {
      final blocks = Directory('/sys/block').listSync();
      for (final block in blocks) {
        final name = block.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.startsWith('loop') ||
            name.startsWith('ram') ||
            name.startsWith('dm-') ||
            name.startsWith('md') ||
            name.startsWith('zram')) {
          continue;
        }
        candidates
          ..add('${block.path}/device/serial')
          ..add('${block.path}/device/wwid');
      }
    } catch (_) {
      // 忽略，继续用 DMI 序列号。
    }
    for (final path in candidates) {
      try {
        final value = (await File(path).readAsString()).trim();
        if (value.isNotEmpty && value != '0' && value != 'None') {
          return value;
        }
      } catch (_) {
        // 继续下一个候选。
      }
    }
    return null;
  }

  static Future<String?> _readMacosMac() async {
    try {
      final result = await Process.run(
        'ifconfig',
        ['en0'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
      final match = RegExp(
        r'ether\s+([0-9a-fA-F:]{17})',
      ).firstMatch(result.stdout as String);
      final mac = match?.group(1)?.toUpperCase();
      return _isUsableMac(mac?.toLowerCase() ?? '') ? mac : null;
    } catch (_) {
      return null;
    }
  }

  static bool _isVirtualInterface(String name) {
    const prefixes = [
      'lo',
      'veth',
      'docker',
      'br-',
      'virbr',
      'tun',
      'tap',
      'utun',
      'clash',
      'meta',
      'wg',
    ];
    return prefixes.any(name.startsWith);
  }

  static bool _isUsableMac(String mac) {
    if (mac.length != 17 || !mac.contains(':')) {
      return false;
    }
    return mac != '00:00:00:00:00:00' && mac != 'ff:ff:ff:ff:ff:ff';
  }
}
