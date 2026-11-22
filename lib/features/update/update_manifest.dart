import 'dart:io';

import 'package:fl_clash/common/common.dart';

/// 更新清单的来源。
///
/// 面板（`/api/v1/user/client/update`）是权威来源，带 sha256 + RSA 签名；
/// GitHub Releases 只在面板不可达时兜底，只有版本号和安装包，没有签名。
enum UpdateSource { panel, github }

/// 当前平台 + 架构的更新标识，与服务端 `v2_client_update.platform` 对齐。
///
/// S-36：原来写死 `windows-x64`，Android / 其它平台向面板请求只会拿到
/// `data: null`（白名单空档）。这里按运行平台上报；返回 null 表示该平台
/// 不走面板通道（直接跳过，交给 GitHub 兜底），避免拿 Windows 清单。
///
/// 注意：Windows 目前只发 x64 安装版，ARM64 Windows 上运行同一个构建也用它。
String? get currentUpdatePlatformId {
  if (Platform.isWindows) {
    return 'windows-x64';
  }
  if (Platform.isAndroid) {
    return 'android-arm64';
  }
  if (Platform.isMacOS) {
    return 'macos-arm64';
  }
  if (Platform.isLinux) {
    return 'linux-x64';
  }
  return null;
}

/// 更新通道，服务端按 (platform, channel) 取最新已发布记录。
const updateChannel = 'stable';

/// 签名原文的第一行，服务端 `ClientUpdateService` 必须用完全相同的拼接方式。
const updateSignaturePrefix = 'dawn-update-v1';

/// 一次更新检查得到的清单。
class UpdateManifest {
  const UpdateManifest({
    required this.source,
    required this.versionName,
    required this.versionCode,
    required this.minVersionCode,
    required this.fileName,
    required this.fileSize,
    required this.sha256,
    required this.signature,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.mandatory,
  });

  /// 面板接口 `data` 字段。
  factory UpdateManifest.fromPanel(Map<String, dynamic> data) {
    return UpdateManifest(
      source: UpdateSource.panel,
      versionName: (data['version_name'] ?? '').toString(),
      versionCode: _asInt(data['version_code']),
      minVersionCode: _asInt(data['min_version_code']),
      fileName: (data['file_name'] ?? '').toString(),
      fileSize: _asInt(data['file_size']),
      sha256: (data['sha256'] ?? '').toString().toLowerCase(),
      signature: (data['signature'] ?? '').toString(),
      downloadUrl: (data['download_url'] ?? '').toString(),
      releaseNotes: (data['release_notes'] ?? '').toString(),
      mandatory: data['mandatory'] == true,
    );
  }

  /// GitHub Releases 兜底：没有 version_code，也没有签名，只能按版本名比较。
  factory UpdateManifest.fromGitHub(
    Map<String, dynamic> release, {
    required String downloadUrl,
    required String fileName,
    required String sha256,
    required int fileSize,
  }) {
    final tag = (release['tag_name'] as String? ?? '').trim();
    final versionName = tag.startsWith('v') ? tag.substring(1) : tag;
    return UpdateManifest(
      source: UpdateSource.github,
      versionName: versionName,
      versionCode: 0,
      minVersionCode: 0,
      fileName: fileName,
      fileSize: fileSize,
      sha256: sha256.toLowerCase(),
      signature: '',
      downloadUrl: downloadUrl,
      releaseNotes: (release['body'] as String? ?? '').trim(),
      mandatory: false,
    );
  }

  final UpdateSource source;
  final String versionName;

  /// 构建号（`pubspec.yaml` 的 `+` 后面那串），0 表示来源没提供。
  final int versionCode;

  /// 低于这个构建号的客户端必须强制更新；0 表示不限制。
  final int minVersionCode;

  final String fileName;
  final int fileSize;
  final String sha256;

  /// Base64 的 RSA-SHA256 签名；GitHub 兜底为空。
  final String signature;

  /// 安装包直链，指向上传服务器而不是面板。
  final String downloadUrl;

  final String releaseNotes;

  /// 服务端标记的强制更新。
  final bool mandatory;

  bool get hasSignature => signature.isNotEmpty;

  /// 这份清单必须带 RSA 签名才允许安装（S-36）。
  ///
  /// 面板清单是权威来源，必须验签；GitHub 兜底没有签名能力（只有同源的
  /// SHA256SUMS），只能靠 sha256 + HTTPS —— 这是产品上保留兜底的代价，
  /// 所以面板清单绝不能退化成「有签名才验、没签名就跳过」。
  bool get requiresSignature => source == UpdateSource.panel;

  /// 签名原文：`dawn-update-v1\n{windows-x64}\n{version_code}\n{file_size}\n{sha256}`。
  String get signaturePayload {
    return [
      updateSignaturePrefix,
      currentUpdatePlatformId ?? '',
      '$versionCode',
      '$fileSize',
      sha256,
    ].join('\n');
  }

  /// 相对当前客户端是否更新。
  bool isNewerThan({required int currentCode, required String currentVersion}) {
    if (versionCode > 0 && currentCode > 0) {
      return versionCode > currentCode;
    }
    return compareVersions(versionName, currentVersion) > 0;
  }

  /// 是否必须强制更新（服务端标记，或当前构建号低于最低支持构建号）。
  bool requiresForce(int currentCode) {
    if (mandatory) {
      return true;
    }
    return minVersionCode > 0 && currentCode > 0 && currentCode < minVersionCode;
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
