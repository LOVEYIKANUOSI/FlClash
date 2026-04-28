import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/widgets/start_button.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView>
    with SingleTickerProviderStateMixin {
  AnimationController? _bgController;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _bgController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 背景装饰
            _BackgroundDecoration(controller: _bgController),
            // 主内容
            _buildBody(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        // 顶部订阅信息栏
        _buildSubscriptionBar(),
        // 中间连接按钮区域
        Expanded(child: _buildCenterSection()),
        // 底部模式选择 + 流量
        _buildBottomSection(),
      ],
    );
  }

  Widget _buildSubscriptionBar() {
    return Consumer(
      builder: (_, ref, _) {
        final profiles = ref.watch(profilesProvider);
        final currentProfileId = ref.watch(currentProfileIdProvider);
        final currentProfile = ref.watch(currentProfileProvider);

        if (profiles.isEmpty) return Container();

        return Container(
          margin: EdgeInsets.fromLTRB(16, 16, 16, 0),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 订阅选择 + 刷新
              Row(
                children: [
                  // 刷新按钮
                  IconButton(
                    onPressed: () {
                      appController.updateProfiles();
                    },
                    icon: Icon(Icons.refresh, size: 20),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  SizedBox(width: 4),
                  // 订阅下拉选择
                  Expanded(
                    child: _SubscriptionDropdown(
                      profiles: profiles,
                      currentProfileId: currentProfileId,
                    ),
                  ),
                ],
              ),
              // 流量进度条
              SizedBox(height: 6),
              _SubscriptionInfo(subscriptionInfo: currentProfile?.subscriptionInfo),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCenterSection() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildConnectionButton(),
          SizedBox(height: 16),
          _buildConnectionStatus(),
        ],
      ),
    );
  }

  Widget _buildConnectionButton() {
    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Center(child: StartButton()),
    );
  }

  Widget _buildConnectionStatus() {
    return Consumer(
      builder: (_, ref, _) {
        final coreStatus = ref.watch(coreStatusProvider);
        final runTime = ref.watch(runTimeProvider);

        final (text, color) = switch (coreStatus) {
          CoreStatus.connected => (
              utils.getTimeText(runTime),
              Theme.of(context).colorScheme.primary,
            ),
          CoreStatus.connecting => (
              appLocalizations.connecting,
              Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          CoreStatus.disconnected => (
              appLocalizations.disconnected,
              Theme.of(context).colorScheme.error,
            ),
        };

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            SizedBox(height: 2),
            Text(
              '点击连接',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBottomSection() {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 出站模式选择
          _OutboundModeSelector(),
          SizedBox(height: 12),
          Divider(height: 1),
          SizedBox(height: 12),
          // 代理模式
          _ProxyModeSelector(),
          SizedBox(height: 12),
          Divider(height: 1),
          SizedBox(height: 12),
          // 流量统计
          _TrafficStats(),
        ],
      ),
    );
  }
}

/// 背景装饰——带旋转的世界地图纹理
class _BackgroundDecoration extends StatelessWidget {
  final AnimationController? controller;
  const _BackgroundDecoration({this.controller});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: controller!,
      builder: (_, __) {
        return Transform.rotate(
          angle: controller!.value * 2 * pi * 0.1,
          child: Container(
            alignment: Alignment.center,
            child: Icon(
              Icons.public,
              size: MediaQuery.of(context).size.width * 0.6,
              color: color.withOpacity(0.04),
            ),
          ),
        );
      },
    );
  }
}

/// 订阅下拉选择
class _SubscriptionDropdown extends StatelessWidget {
  final List<dynamic> profiles;
  final int? currentProfileId;

  const _SubscriptionDropdown({required this.profiles, this.currentProfileId});

  @override
  Widget build(BuildContext context) {
    final currentProfile = profiles.cast<dynamic>().firstWhere(
      (p) => p.id == currentProfileId,
      orElse: () => profiles.first,
    );

    return Consumer(
      builder: (_, ref, __) {
        return DropdownButton<int>(
          value: currentProfile.id,
          isExpanded: true,
          underline: Container(),
          borderRadius: BorderRadius.circular(12),
          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: EdgeInsets.zero,
          style: Theme.of(context).textTheme.bodyLarge,
          items: profiles
              .map<DropdownMenuItem<int>>(
                (p) => DropdownMenuItem(
                  value: p.id,
                  child: Text(
                    p.label.isNotEmpty ? p.label : 'Profile #${p.id}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              )
              .toList(),
          onChanged: (id) {
            if (id == null) return;
            ref.read(currentProfileIdProvider.notifier).value = id;
          },
        );
      },
    );
  }
}

/// 订阅流量信息
class _SubscriptionInfo extends StatelessWidget {
  final SubscriptionInfo? subscriptionInfo;
  const _SubscriptionInfo({this.subscriptionInfo});

  @override
  Widget build(BuildContext context) {
    if (subscriptionInfo == null) {
      return Text(
        appLocalizations.infiniteTime,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
    }

    final upload = subscriptionInfo!.upload;
    final download = subscriptionInfo!.download;
    final total = subscriptionInfo!.total;
    final use = upload + download;
    final progress = total > 0 ? (use / total).clamp(0.0, 1.0) : 0.0;

    final useShow = use.traffic.show;
    final totalShow = total > 0 ? total.traffic.show : '∞ GiB';
    final expireText = subscriptionInfo!.expire != 0
        ? DateTime.fromMillisecondsSinceEpoch(
            subscriptionInfo!.expire * 1000,
          ).show
        : appLocalizations.infiniteTime;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (total > 0)
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
            borderRadius: BorderRadius.circular(2),
          ),
        SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$useShow / $totalShow',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            Text(
              '剩余 $expireText',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 出站模式选择器
class _OutboundModeSelector extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (_, ref, _) {
        final mode = ref.watch(
          patchClashConfigProvider.select((state) => state.mode),
        );
        return Row(
          children: Mode.values.map((m) {
            final isSelected = m == mode;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Material(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: () => appController.changeMode(m),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _modeIcon(m),
                            size: 18,
                            color: isSelected
                                ? Theme.of(context).colorScheme.onPrimaryContainer
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          SizedBox(height: 2),
                          Text(
                            Intl.message(m.name),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.onPrimaryContainer
                                      : Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontWeight: isSelected ? FontWeight.w600 : null,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  IconData _modeIcon(Mode mode) {
    return switch (mode) {
      Mode.rule => Icons.tune,
      Mode.global => Icons.language,
      Mode.direct => Icons.swap_horiz,
    };
  }
}

/// 流量统计
class _TrafficStats extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (_, ref, _) {
        final totalTraffic = ref.watch(totalTrafficProvider);
        final up = totalTraffic.up;
        final down = totalTraffic.down;
        final primaryColor = globalState.theme.darken3PrimaryContainer;
        final secondaryColor = globalState.theme.darken2SecondaryContainer;

        return Row(
          children: [
            Expanded(
              child: _TrafficStatItem(
                label: appLocalizations.upload,
                value: up,
                color: primaryColor,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: _TrafficStatItem(
                label: appLocalizations.download,
                value: down,
                color: secondaryColor,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 单项流量统计
class _TrafficStatItem extends StatelessWidget {
  final String label;
  final num value;
  final Color color;

  const _TrafficStatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        SizedBox(height: 4),
        Text(
          '${value.traffic.value} ${value.traffic.unit}',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
        ),
      ],
    );
  }
}

/// 代理模式选择（TUN / 系统代理）
class _ProxyModeSelector extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (_, ref, _) {
        final tunEnabled = ref.watch(
          patchClashConfigProvider.select((state) => state.tun.enable),
        );
        final systemProxy = ref.watch(
          networkSettingProvider.select((state) => state.systemProxy),
        );

        return Row(
          children: [
            Expanded(
              child: _ToggleChip(
                icon: Icons.stacked_line_chart,
                label: appLocalizations.tun,
                value: tunEnabled,
                onChanged: (v) {
                  ref.read(patchClashConfigProvider.notifier).update(
                    (state) => state.copyWith.tun(enable: v),
                  );
                },
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: _ToggleChip(
                icon: Icons.shuffle,
                label: appLocalizations.systemProxy,
                value: systemProxy,
                onChanged: (v) {
                  ref.read(networkSettingProvider.notifier).update(
                    (state) => state.copyWith(systemProxy: v),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 切换按钮
class _ToggleChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: value
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: value
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: value
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: value ? FontWeight.w600 : null,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
