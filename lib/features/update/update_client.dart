import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/v2board/app_config.dart';

import 'update_manifest.dart';

/// 面板返回 401/403，说明登录态已失效（调用方应保留凭据并稍后重试）。
class UpdateCheckUnauthorized implements Exception {
  const UpdateCheckUnauthorized();

  @override
  String toString() => '登录状态已失效';
}

/// 当前平台不走面板更新通道（面板没有该平台的清单）。
class UpdateChannelUnsupported implements Exception {
  const UpdateChannelUnsupported(this.platform);

  final String? platform;

  @override
  String toString() => '面板不支持当前平台（${platform ?? 'unknown'}）的更新清单';
}

/// 拉取更新清单：面板优先，GitHub 仅兜底。
///
/// 面板接口需要登录态（`Authorization: authData`），返回 `data: null` 表示
/// 没有新版本；GitHub 兜底只在面板请求失败时调用。
class UpdateClient {
  UpdateClient._();

  static final UpdateClient instance = UpdateClient._();

  /// 面板清单请求也必须拒绝坏证书（S-37）：清单里的 download_url 会被安装，
  /// 不能受「校验 TLS 证书」用户开关影响。
  final Dio _panelDio = Dio(
    BaseOptions(
      headers: {'User-Agent': browserUa, 'Accept': 'application/json'},
      responseType: ResponseType.json,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (status) => status != null,
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()..badCertificateCallback = ((_, _, _) => false),
    );

  /// 查询面板 `/api/v1/user/client/update`。
  ///
  /// 平台标识按运行平台上报（S-36）；当前平台没有面板通道时抛
  /// [UpdateChannelUnsupported]，调用方直接走 GitHub 兜底。
  Future<UpdateManifest?> fetchFromPanel({
    required String baseUrl,
    required String authData,
    required int currentCode,
  }) async {
    final platform = currentUpdatePlatformId;
    if (platform == null) {
      throw UpdateChannelUnsupported(platform);
    }
    final response = await _panelDio.get<dynamic>(
      '${AppConfig.normalizeUrl(baseUrl)}/api/v1/user/client/update',
      queryParameters: {
        'platform': platform,
        'channel': updateChannel,
        'code': currentCode,
      },
      options: Options(headers: {'Authorization': authData}),
    );
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw const UpdateCheckUnauthorized();
    }
    if (status != 200) {
      // 404 = 面板还没上更新接口，5xx = 面板故障；都交给 GitHub 兜底。
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: '面板更新接口返回 HTTP $status',
      );
    }
    final body = response.data;
    if (body is! Map) {
      return null;
    }
    final data = body['data'];
    if (data is! Map) {
      return null;
    }
    final manifest = UpdateManifest.fromPanel(
      Map<String, dynamic>.from(data),
    );
    if (manifest.versionName.isEmpty || manifest.downloadUrl.isEmpty) {
      return null;
    }
    return manifest;
  }

  /// GitHub Releases 兜底：只支持安装版（Inno Setup），走内核代理。
  ///
  /// 返回 null 表示当前构建不支持自更新（portable 包）或没有发布资产。
  Future<UpdateManifest?> fetchFromGitHub() async {
    final release = await request.latestRelease();
    final tag = (release['tag_name'] as String? ?? '').trim();
    if (tag.isEmpty) {
      return null;
    }
    final suffix = selfUpdateSuffix;
    if (suffix == null) {
      return null;
    }
    final fileName = releaseAssetName(tag, suffix);
    final assets = (release['assets'] as List? ?? const []).whereType<Map>();
    var downloadUrl = releaseAssetUri(tag, fileName).toString();
    var fileSize = 0;
    for (final asset in assets) {
      if (asset['name'] != fileName) {
        continue;
      }
      final url = asset['browser_download_url']?.toString();
      if (url != null && url.isNotEmpty) {
        downloadUrl = url;
      }
      fileSize = (asset['size'] as num?)?.toInt() ?? 0;
      break;
    }
    final sumsResponse = await request.getTextResponseForUrl(
      releaseAssetUri(tag, releaseChecksumsName).toString(),
    );
    final sha256 = releaseChecksum(sumsResponse.data ?? '', fileName);
    if (sha256 == null) {
      throw const FormatException('GitHub release 缺少 SHA256SUMS');
    }
    return UpdateManifest.fromGitHub(
      release,
      downloadUrl: downloadUrl,
      fileName: fileName,
      sha256: sha256,
      fileSize: fileSize,
    );
  }
}
