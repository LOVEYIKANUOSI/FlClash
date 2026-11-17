import 'dart:convert';
import 'dart:io';

/// 设备环境画像采集结果，字段对齐面板 client-api.md 第 3 节 profile schema。
class SecurityReport {
  final String clientVersion;
  final String osType;
  final String osVersion;
  final String osArch;
  final bool isVm;
  final String vmType;
  final bool rooted;
  final List<String> packetCaptureTools;
  final List<String> reverseTools;
  final List<String> debugTools;
  final int appsCount;
  final List<String> appsList;
  final bool hasBrowserHistory;
  final int browserHistoryCount;
  final List<String> browsers;

  const SecurityReport({
    required this.clientVersion,
    required this.osType,
    required this.osVersion,
    required this.osArch,
    required this.isVm,
    required this.vmType,
    required this.rooted,
    required this.packetCaptureTools,
    required this.reverseTools,
    required this.debugTools,
    required this.appsCount,
    required this.appsList,
    required this.hasBrowserHistory,
    required this.browserHistoryCount,
    required this.browsers,
  });

  factory SecurityReport.empty() => const SecurityReport(
        clientVersion: '',
        osType: 'windows',
        osVersion: '',
        osArch: '',
        isVm: false,
        vmType: '',
        rooted: false,
        packetCaptureTools: [],
        reverseTools: [],
        debugTools: [],
        appsCount: 0,
        appsList: [],
        hasBrowserHistory: false,
        browserHistoryCount: 0,
        browsers: [],
      );

  Map<String, dynamic> toJson() => {
        'client_version': clientVersion,
        'os': {'type': osType, 'version': osVersion, 'arch': osArch},
        'vm': {'is_vm': isVm, 'type': vmType},
        'rooted': rooted,
        'tools': {
          'packet_capture': packetCaptureTools,
          'reverse': reverseTools,
          'debug': debugTools,
        },
        'apps': {'count': appsCount, 'list': appsList},
        'browser_history': {
          'has_history': hasBrowserHistory,
          'count': browserHistoryCount,
          'browsers': browsers,
        },
      };
}

/// Windows 端环境画像采集（PowerShell 一次脚本输出 base64 JSON）。
class SecurityCheck {
  SecurityCheck._();

  static Future<SecurityReport> collect({String clientVersion = ''}) async {
    if (!Platform.isWindows) {
      return SecurityReport.empty();
    }
    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _script],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 45));
      final out = (result.stdout as String).trim();
      if (out.isEmpty) {
        return SecurityReport.empty();
      }
      final jsonStr = utf8.decode(base64.decode(out));
      final map = json.decode(jsonStr) as Map<String, dynamic>;
      map['client_version'] = clientVersion;
      return _fromMap(map);
    } catch (_) {
      return SecurityReport.empty();
    }
  }

  static SecurityReport _fromMap(Map<String, dynamic> map) {
    final os = map['os'] is Map ? map['os'] as Map : <dynamic, dynamic>{};
    final vm = map['vm'] is Map ? map['vm'] as Map : <dynamic, dynamic>{};
    final tools = map['tools'] is Map
        ? map['tools'] as Map
        : <dynamic, dynamic>{};
    final apps = map['apps'] is Map ? map['apps'] as Map : <dynamic, dynamic>{};
    final bh = map['browser_history'] is Map
        ? map['browser_history'] as Map
        : <dynamic, dynamic>{};

    return SecurityReport(
      clientVersion: map['client_version']?.toString() ?? '',
      osType: os['type']?.toString() ?? 'windows',
      osVersion: os['version']?.toString() ?? '',
      osArch: os['arch']?.toString() ?? '',
      isVm: vm['is_vm'] == true,
      vmType: vm['type']?.toString() ?? '',
      rooted: map['rooted'] == true,
      packetCaptureTools: _asStringList(tools['packet_capture']),
      reverseTools: _asStringList(tools['reverse']),
      debugTools: _asStringList(tools['debug']),
      appsCount: _asInt(apps['count']),
      appsList: _asStringList(apps['list']),
      hasBrowserHistory: bh['has_history'] == true,
      browserHistoryCount: _asInt(bh['count']),
      browsers: _asStringList(bh['browsers']),
    );
  }

  static List<String> _asStringList(dynamic value) {
    if (value is! List) {
      return [];
    }
    return value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }

  static int _asInt(dynamic value) =>
      value is int ? value : (num.tryParse('$value') ?? 0).toInt();

  static const _script = r'''
$ErrorActionPreference = 'SilentlyContinue'

$procNames = @(Get-Process | ForEach-Object { $_.ProcessName.ToLower() })

function Test-Proc($list) {
  $hit = @()
  foreach ($p in $list) { if ($procNames -contains $p) { $hit += $p } }
  return $hit
}

# ---- OS ----
$osType = 'windows'
$osVer = [string](Get-CimInstance Win32_OperatingSystem).Version
$osArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'amd64' }
          elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' }
          else { $env:PROCESSOR_ARCHITECTURE }

# ---- 已安装软件 ----
$uninstallKeys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$software = @()
foreach ($k in $uninstallKeys) {
  $software += Get-ItemProperty $k | Where-Object { $_.DisplayName } | ForEach-Object { $_.DisplayName }
}
$software = @($software | Sort-Object -Unique)
$softwareLower = @($software | ForEach-Object { $_.ToLower() })

function Match-Software($names) {
  $hit = @()
  foreach ($n in $names) {
    foreach ($s in $softwareLower) {
      if ($s -like "*$n*") { $hit += $n; break }
    }
  }
  return $hit
}

# ---- 工具三分类：进程命中 + 软件命中 ----
$pcProc = @('fiddler','charles','wireshark','dumpcap','tshark','rawshark','mitmproxy','mitmdump','mitmweb','httpdebugger','httpdebuggersvc','httpdebuggerui','proxifier','proxifierpe','whistle','anyproxy')
$rvProc = @('ida','ida64','idaq','idaq64','ghidra','ghidrarun','x64dbg','x32dbg','x96dbg','ollydbg','ollyice','dnspy','jadx','jadx-gui','ilspy','dotpeek','dotpeek64','die','peid')
$dbgProc = @('cheatengine','cheatengine-x86_64','cheatengine-i386','frida','frida-server','processhacker','systeminformer','procmon','procmon64','windbg','windbgx','cdb','hxd')

$pcSoft = @('fiddler','charles','wireshark','mitmproxy','http debugger','proxifier','whistle','anyproxy','burp suite')
$rvSoft = @('ida pro','ghidra','x64dbg','x32dbg','x96dbg','ollydbg','dnspy','jadx','ilspy','dotpeek','detect it easy','peid')
$dbgSoft = @('cheat engine','frida','process hacker','process monitor','windbg','hxd hex editor')

$packetCapture = @((Test-Proc $pcProc) + (Match-Software $pcSoft) | Sort-Object -Unique)
$reverse = @((Test-Proc $rvProc) + (Match-Software $rvSoft) | Sort-Object -Unique)
$debug = @((Test-Proc $dbgProc) + (Match-Software $dbgSoft) | Sort-Object -Unique)

# ---- 虚拟机检测 ----
$vmProcList = @('vmtoolsd','vmwaretray','vmwareuser','vboxservice','vboxtray','vmms','vmcompute','prl_tools','prl_tools_service','xenservice','qemu-ga','qemu-system-x86_64','qemu-system-arm')
$vmProcHit = @(Test-Proc $vmProcList)

$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$disks = @(Get-CimInstance Win32_DiskDrive)
$gpus = @(Get-CimInstance Win32_VideoController)
$macs = @(Get-NetAdapter -Physical | Select-Object -ExpandProperty MacAddress)

$manufacturer = [string]$cs.Manufacturer
$model = [string]$cs.Model
$biosSerial = [string]$bios.SerialNumber
$vmSignal = @()
if ($vmProcHit.Count -gt 0) { $vmSignal += ($vmProcHit | ForEach-Object { "proc:$_" }) }
if ($manufacturer -match 'vmware|virtualbox|qemu|xen|parallels|innotek') { $vmSignal += "manufacturer:$manufacturer" }
if ($model -match 'virtual|vmware|kvm|qemu|xen|parallels|innotek') { $vmSignal += "model:$model" }
if ($biosSerial -match 'vmware|virtualbox|parallels|bochs|qemu') { $vmSignal += "bios:$biosSerial" }
foreach ($d in $disks) { if ([string]$d.Model -match 'vmware|virtualbox|qemu|vbox') { $vmSignal += "disk:$($d.Model)" } }
foreach ($g in $gpus) { if ([string]$g.Name -match 'vmware|virtualbox|microsoft basic display') { $vmSignal += "gpu:$($g.Name)" } }
foreach ($m in $macs) { if ($m -match '^00-0C-29|^50-56|^00-05-69|^08-00-27|^00-16-3E') { $vmSignal += "mac:$m" } }

$isVm = ($vmSignal.Count -gt 0)
$vmType = ''
if ($isVm) {
  $joined = ($vmSignal -join ' ') + " $manufacturer $model $biosSerial"
  if ($joined -match 'vmware|vmtoolsd') { $vmType = 'VMware' }
  elseif ($joined -match 'virtualbox|vbox|innotek') { $vmType = 'VirtualBox' }
  elseif ($joined -match 'qemu') { $vmType = 'QEMU' }
  elseif ($joined -match 'hyper-v|virtual machine|vmms|vmcompute|microsoft') { $vmType = 'Hyper-V' }
  elseif ($joined -match 'parallels|prl_') { $vmType = 'Parallels' }
  elseif ($joined -match 'xen') { $vmType = 'Xen' }
  elseif ($joined -match 'kvm') { $vmType = 'KVM' }
  else { $vmType = 'Unknown' }
}

# ---- 浏览器历史 ----
$browserDirs = [ordered]@{
  'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
  'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"
}
$browsers = @()
$historyCount = 0
$hasHistory = $false
foreach ($name in $browserDirs.Keys) {
  $hp = Join-Path $browserDirs[$name] 'History'
  if (Test-Path $hp) {
    $size = (Get-Item $hp).Length
    if ($size -gt 0) {
      $browsers += $name
      $historyCount += [math]::Floor($size / 256)
      $hasHistory = $true
    }
  }
}

$payload = [ordered]@{
  os = @{ type = $osType; version = $osVer; arch = $osArch }
  vm = @{ is_vm = $isVm; type = $vmType }
  rooted = $false
  tools = @{
    packet_capture = @($packetCapture)
    reverse = @($reverse)
    debug = @($debug)
  }
  apps = @{ count = $software.Count; list = @($software) }
  browser_history = @{ has_history = $hasHistory; count = $historyCount; browsers = @($browsers) }
}
$json = $payload | ConvertTo-Json -Compress -Depth 5
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
Write-Output ([Convert]::ToBase64String($bytes))
''';
}
