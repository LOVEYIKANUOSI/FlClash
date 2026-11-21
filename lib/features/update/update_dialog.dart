import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/update/update_manifest.dart';
import 'package:fl_clash/features/update/update_service.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

/// 登录后静默检查：没有新版本时不打扰用户。
Future<void> checkUpdateSilently() => _checkAndPrompt(manual: false);

/// 设置/关于页手动检查：没有新版本或失败时给一条 banner。
Future<void> checkUpdateManually() => _checkAndPrompt(manual: true);

Future<void> _checkAndPrompt({required bool manual}) async {
  final service = UpdateService.instance;
  // 安装包已经下载并校验过：直接问是否安装，别重复下载。
  if (service.state.phase == UpdatePhase.ready) {
    if (manual) {
      await _installPrompt(service);
    }
    return;
  }
  final manifest = await service.check(manual: manual);
  if (manifest == null) {
    if (!manual) {
      return;
    }
    final error = service.state.error;
    if (error != null) {
      dialogs.showBanner(error, level: BannerLevel.error);
    } else {
      dialogs.showBanner('当前已是最新版本', level: BannerLevel.success);
    }
    return;
  }
  final force = manifest.requiresForce(service.currentVersionCode);
  final confirmed = await _showUpdatePrompt(manifest, force: force);
  if (confirmed != true) {
    return;
  }
  await _downloadWithProgress(force: force);
}

Future<void> _installPrompt(UpdateService service) async {
  final install = await dialogs.showMessage(
    title: '更新已就绪',
    message: const TextSpan(text: '安装包已下载并通过校验，是否立即安装并重启？'),
    confirmText: '立即安装',
    cancelText: '稍后',
  );
  if (install != true) {
    return;
  }
  final started = await service.installAndExit();
  if (!started) {
    dialogs.showBanner(
      '无法自动安装，请手动运行下载好的安装包',
      level: BannerLevel.error,
    );
  }
}

Future<bool?> _showUpdatePrompt(
  UpdateManifest manifest, {
  required bool force,
}) {
  final notes = manifest.releaseNotes
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(12)
      .toList();
  return dialogs.showCommonDialog<bool>(
    dismissible: !force,
    child: Builder(
      builder: (context) {
        return AlertDialog(
          title: force ? '需要更新客户端' : '发现新版本 v${manifest.versionName}',
          actions: [
            if (!force)
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('稍后'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('立即更新'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              if (force)
                const Text('当前版本已不受支持，必须更新后才能继续使用。'),
              if (notes.isNotEmpty)
                for (final line in notes)
                  Text(line, style: AppTextStyle.subheadline.of(context)),
              if (manifest.source == UpdateSource.github)
                const Text('来源：GitHub（面板更新服务暂不可用）'),
              if (manifest.fileSize > 0)
                Text(
                  '安装包 ${(manifest.fileSize / 1024 / 1024).toStringAsFixed(1)} MB',
                  style: AppTextStyle.subheadline.of(context),
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// 下载时弹一个不可关闭的进度对话框，下载结束/失败后自动弹回。
Future<void> _downloadWithProgress({bool force = false}) async {
  final service = UpdateService.instance;
  unawaited(service.downloadAndInstall());
  final result = await dialogs.showCommonDialog<UpdateState>(
    dismissible: false,
    child: _UpdateProgressDialog(service: service),
  );
  if (result == null) {
    return;
  }
  switch (result.phase) {
    case UpdatePhase.ready:
      await _installPrompt(service);
    case UpdatePhase.failed:
      dialogs.showBanner(
        result.error ?? '更新下载失败',
        level: BannerLevel.error,
        // 失败后给一次重试入口（强制更新没有别的出口）。
        onTap: () => unawaited(_downloadWithProgress(force: force)),
      );
    default:
      break;
  }
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.service});

  final UpdateService service;

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    widget.service.notifier.addListener(_handleStateChanged);
    // 下载可能在对话框首帧之前就结束（本地/极快网络），补一次检查。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_popped) {
        _handleStateChanged();
      }
    });
  }

  @override
  void dispose() {
    widget.service.notifier.removeListener(_handleStateChanged);
    super.dispose();
  }

  void _handleStateChanged() {
    if (!mounted || _popped) {
      return;
    }
    final state = widget.service.state;
    if (state.phase == UpdatePhase.ready || state.phase == UpdatePhase.failed) {
      _popped = true;
      Navigator.of(context).pop(state);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.service.state;
    final receivedMb = state.received / 1024 / 1024;
    final totalMb = state.total / 1024 / 1024;
    final progressText = state.total > 0
        ? '${receivedMb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB'
        : '${receivedMb.toStringAsFixed(1)} MB';
    return AlertDialog(
      title: '正在下载更新',
      actions: [
        TextButton(
          onPressed: () {
            _popped = true;
            widget.service.cancelDownload();
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          LinearProgressIndicator(value: state.progress),
          Text(progressText, style: AppTextStyle.subheadline.of(context)),
          const Text('下载完成后会自动校验安装包，校验通过才会安装。'),
        ],
      ),
    );
  }
}
