import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/update/update_manifest.dart';
import 'package:fl_clash/features/v2board/app_config.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, VoidCallback, visibleForTesting;
import 'package:path/path.dart' show join;

import 'update_client.dart';
import 'update_verify.dart';

/// 更新流程的阶段。
enum UpdatePhase { idle, checking, available, downloading, ready, failed }

/// 更新功能对 UI 暴露的完整状态。
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.manifest,
    this.received = 0,
    this.total = 0,
    this.downloadPath,
    this.error,
  });

  final UpdatePhase phase;
  final UpdateManifest? manifest;
  final int received;
  final int total;
  final String? downloadPath;
  final String? error;

  bool get isBusy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;

  bool get hasNewVersion => manifest != null && phase != UpdatePhase.idle;

  double get progress {
    if (total <= 0) {
      return 0;
    }
    return (received / total).clamp(0.0, 1.0);
  }

  UpdateState copyWith({
    UpdatePhase? phase,
    UpdateManifest? manifest,
    int? received,
    int? total,
    String? downloadPath,
    String? error,
    bool clearError = false,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      manifest: manifest ?? this.manifest,
      received: received ?? this.received,
      total: total ?? this.total,
      downloadPath: downloadPath ?? this.downloadPath,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 客户端自更新：面板清单优先、GitHub 兜底、直链下载、sha256 + RSA 校验。
///
/// 用 `ValueNotifier` 而不是 riverpod provider，避免改上游生成的 provider
/// 代码；UI 直接 `ValueListenableBuilder` 监听。
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 面板检查失败后等多久再试 GitHub 兜底（面板域名故障时不要拖太久）。
  static const _panelTimeout = Duration(seconds: 12);

  /// 登录后延迟多久做第一次检查。
  static const _firstCheckDelay = Duration(seconds: 5);

  /// 自动检查间隔。
  static const _checkInterval = Duration(hours: 6);

  final ValueNotifier<UpdateState> notifier = ValueNotifier(
    const UpdateState(),
  );

  final AuthStore _authStore = AuthStore();

  /// 下载用独立 Dio，强制 DIRECT：安装包在下载服务器上，不走用户节点。
  ///
  /// S-36/S-37：安装包下载必须自己拒绝坏证书，不能受设置里的
  /// 「校验 TLS 证书」开关影响（用户关掉全局校验时，更新通道仍要严格）。
  late final Dio _downloadDio = Dio(
    BaseOptions(
      headers: {'User-Agent': browserUa, 'Accept-Encoding': 'identity'},
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 30),
      validateStatus: (status) => status != null,
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..badCertificateCallback = ((_, _, _) => false),
    );

  Timer? _autoCheckTimer;
  VoidCallback? _onUpdateAvailable;
  CancelToken? _downloadCancelToken;

  UpdateState get state => notifier.value;

  /// 当前构建号（`pubspec.yaml` 的 `+` 后半段），无法解析时返回 0。
  int get currentVersionCode =>
      int.tryParse(globalState.packageInfo.buildNumber) ?? 0;

  /// 登录成功后调用：5 秒后检查一次，之后每 6 小时一次。
  ///
  /// [onUpdateAvailable] 在后台检查发现新版本时回调，由 UI 层决定怎么提示
  /// （后台检查本身不弹窗，避免用户正在操作时被打断）。
  void startAutoCheck({VoidCallback? onUpdateAvailable}) {
    _autoCheckTimer?.cancel();
    _onUpdateAvailable = onUpdateAvailable;
    _autoCheckTimer = Timer.periodic(_checkInterval, (_) {
      unawaited(_backgroundCheck());
    });
    Timer(_firstCheckDelay, () {
      unawaited(_backgroundCheck());
    });
  }

  Future<void> _backgroundCheck() async {
    final manifest = await check();
    if (manifest != null) {
      _onUpdateAvailable?.call();
    }
  }

  void stopAutoCheck() {
    _autoCheckTimer?.cancel();
    _autoCheckTimer = null;
    _onUpdateAvailable = null;
  }

  /// 检查更新；[manual] 为 true 时即使没有新版本也会把状态置为 idle 供 UI 提示。
  Future<UpdateManifest?> check({bool manual = false}) async {
    if (state.isBusy) {
      return null;
    }
    final cached = state.manifest;
    if (!manual && state.phase == UpdatePhase.available && cached != null) {
      return cached;
    }
    final previous = state;
    notifier.value = const UpdateState(phase: UpdatePhase.checking);
    try {
      final manifest = await _fetchManifest();
      final next = _evaluate(manifest, manual: manual);
      notifier.value = next;
      return next.manifest;
    } catch (error) {
      commonPrint.log(
        'Update check failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      notifier.value = previous.copyWith(
        phase: UpdatePhase.idle,
        error: '检查更新失败：${userFacingErrorMessage(error, currentAppLocalizations)}',
      );
      return null;
    }
  }

  Future<UpdateManifest?> _fetchManifest() async {
    await _authStore.init();
    final authData = _authStore.authData;
    if (authData == null || authData.isEmpty) {
      // 需求：登录后才能检查更新；未登录不查面板，也不走 GitHub 兜底。
      return null;
    }
    Object? panelError;
    for (final baseUrl in _candidateBaseUrls()) {
      try {
        return await UpdateClient.instance
            .fetchFromPanel(
              baseUrl: baseUrl,
              authData: authData,
              currentCode: currentVersionCode,
            )
            .timeout(_panelTimeout);
      } on UpdateChannelUnsupported catch (error) {
        // 当前平台没有面板更新通道（S-36）：不用逐个域名重试，直接 GitHub。
        commonPrint.log(
          'Update panel channel unsupported: $error',
          logLevel: LogLevel.warning,
        );
        return UpdateClient.instance.fetchFromGitHub();
      } catch (error) {
        panelError = error;
        if (error is UpdateCheckUnauthorized) {
          // 登录态问题交给心跳/会话恢复处理，更新检查不踢人。
          return null;
        }
      }
    }
    commonPrint.log(
      'Update panel unavailable, fallback to GitHub: ${compactError(panelError ?? 'unknown')}',
      logLevel: LogLevel.warning,
    );
    return UpdateClient.instance.fetchFromGitHub();
  }

  UpdateState _evaluate(UpdateManifest? manifest, {required bool manual}) {
    if (manifest == null) {
      // 面板说没有新版本；手动检查时 UI 会据此提示「已是最新」。
      return const UpdateState();
    }
    final isNewer = manifest.isNewerThan(
      currentCode: currentVersionCode,
      currentVersion: globalState.packageInfo.version,
    );
    if (!isNewer) {
      return const UpdateState(phase: UpdatePhase.idle);
    }
    return UpdateState(
      phase: UpdatePhase.available,
      manifest: manifest,
      total: manifest.fileSize,
    );
  }

  List<String> _candidateBaseUrls() {
    final urls = <String>[];
    final primary = _authStore.apiBaseUrl;
    if (primary.isNotEmpty) {
      urls.add(primary);
    }
    for (final domain in _authStore.domainPool) {
      final url = AppConfig.normalizeDomain(domain);
      if (url.isEmpty || urls.contains(url)) {
        continue;
      }
      urls.add(url);
    }
    return urls;
  }

  /// 下载 + 校验 + 安装。
  ///
  /// 校验失败会删掉文件并进入 failed，绝不把未经验证的安装包交给安装器。
  Future<void> downloadAndInstall() async {
    final manifest = state.manifest;
    if (manifest == null) {
      return;
    }
    if (state.phase == UpdatePhase.downloading) {
      return;
    }
    await download(manifest);
  }

  /// 按清单下载并校验安装包。
  ///
  /// [directory] 只给测试用；生产走 `appPath.updateDirPath`。
  @visibleForTesting
  Future<void> download(UpdateManifest manifest, {String? directory}) async {
    final cancelToken = CancelToken();
    _downloadCancelToken = cancelToken;
    notifier.value = state.copyWith(
      phase: UpdatePhase.downloading,
      received: 0,
      total: manifest.fileSize,
      clearError: true,
    );
    String? path;
    try {
      final targetDirectory = directory ?? await appPath.updateDirPath;
      await Directory(targetDirectory).create(recursive: true);
      path = join(targetDirectory, manifest.fileName);
      // 只清掉历史版本的安装包，当前文件的半成品要留着做 Range 续传。
      await for (final entity in Directory(targetDirectory).list()) {
        if (entity is! File || entity.path == path) {
          continue;
        }
        try {
          await entity.delete();
        } on FileSystemException {
          // 旧安装器可能还占着文件，忽略即可。
        }
      }
      final target = File(path);
      var received = 0;
      if (manifest.fileSize > 0 && await target.exists()) {
        received = await target.length();
        if (received >= manifest.fileSize) {
          received = 0;
          await target.delete();
        }
      }
      final response = await _downloadDio.get<ResponseBody>(
        manifest.downloadUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: received > 0 ? {'Range': 'bytes=$received-'} : null,
          validateStatus: (status) =>
              status != null && (status == 200 || status == 206),
        ),
      );
      if (received > 0 && response.statusCode != 206) {
        // 下载服务器不支持 Range：从头写，避免半成品 + 完整包拼出坏文件。
        received = 0;
        if (await target.exists()) {
          await target.delete();
        }
      }
      final totalBytes = manifest.fileSize > 0 ? manifest.fileSize : received;
      var written = received;
      var lastPercent = -1;
      final sink = target.openWrite(
        mode: received > 0 ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response.data!.stream) {
          sink.add(chunk);
          written += chunk.length;
          final percent = totalBytes > 0
              ? (written * 100 ~/ totalBytes)
              : -1;
          if (percent == lastPercent) {
            continue;
          }
          lastPercent = percent;
          final value = state;
          if (value.phase == UpdatePhase.downloading) {
            notifier.value = value.copyWith(
              received: written,
              total: totalBytes,
            );
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      final actualSha256 = await fileSha256(path);
      if (actualSha256 != manifest.sha256) {
        throw UpdateVerifyException(
          'sha256 不匹配（期望 ${manifest.sha256}，实际 $actualSha256）',
        );
      }
      // S-36：面板清单必须带签名并验签通过，不再「有签名才验、没签名就跳过」。
      if (manifest.requiresSignature && !manifest.hasSignature) {
        throw const UpdateVerifyException('服务端清单缺少签名，已拒绝安装');
      }
      if (manifest.hasSignature &&
          !verifyUpdateSignature(
            payload: manifest.signaturePayload,
            signature: manifest.signature,
          )) {
        throw const UpdateVerifyException('安装包签名校验失败');
      }
      notifier.value = state.copyWith(
        phase: UpdatePhase.ready,
        received: manifest.fileSize,
        total: manifest.fileSize,
        downloadPath: path,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) {
        // 用户取消：保留半成品，下次可以续传。
        notifier.value = const UpdateState();
        return;
      }
      if (error is UpdateVerifyException && path != null) {
        // 校验失败的包绝不能留给安装器。
        try {
          await File(path).delete();
        } on FileSystemException {
          // 删不掉也不影响：state 已置 failed，不会走到安装。
        }
      }
      notifier.value = UpdateState(
        phase: UpdatePhase.failed,
        manifest: manifest,
        error: '下载更新失败：${_describeError(error)}',
      );
    } finally {
      if (identical(_downloadCancelToken, cancelToken)) {
        _downloadCancelToken = null;
      }
    }
  }

  /// 把底层异常翻译成用户可读文案。
  ///
  /// 单元测试环境没有加载 AppLocalizations，取不到时退回原始 description。
  String _describeError(Object error) {
    if (error is UpdateVerifyException) {
      return error.message;
    }
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '下载超时，请检查网络后重试';
        case DioExceptionType.connectionError:
          return '下载服务器连接失败，请检查网络后重试';
        default:
          break;
      }
    }
    try {
      return userFacingErrorMessage(error, currentAppLocalizations);
    } catch (_) {
      return error.toString();
    }
  }

  /// 安装已校验的安装包并退出应用。
  Future<bool> installAndExit() async {
    final path = state.downloadPath;
    if (path == null || state.phase != UpdatePhase.ready) {
      return false;
    }
    if (!Platform.isWindows || !isInstalledWindowsBuild) {
      return false;
    }
    final started = windows?.runas(path, windowsUpdateArguments(pid));
    if (started != true) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

  void cancelDownload() {
    _downloadCancelToken?.cancel();
  }
}

/// 校验安装包失败。
class UpdateVerifyException implements Exception {
  const UpdateVerifyException(this.message);

  final String message;

  @override
  String toString() => message;
}
