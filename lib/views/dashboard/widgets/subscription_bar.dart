import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/subscription_info_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../style.dart';
import 'card.dart';
import 'profile_detail.dart';

/// 仪表盘顶部的订阅条：当前订阅名、到期时间、流量进度，以及刷新与切换入口。
class SubscriptionBar extends ConsumerWidget {
  const SubscriptionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final profile = ref.watch(currentProfileProvider);
    final switchable = ref.watch(
      profilesProvider.select((profiles) => profiles.length > 1),
    );
    final info = profile?.subscriptionInfo;
    final expire = (info == null || info.expire == 0)
        ? appLocalizations.infiniteTime
        : DateTime.fromMillisecondsSinceEpoch(info.expire * 1000).show;
    final colors = DashboardColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile?.realLabel ?? appLocalizations.addProfile,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.callout.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                    ),
                    if (profile != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        expire,
                        maxLines: 1,
                        style: AppTextStyle.footnote.of(context).toLight,
                      ),
                    ],
                  ],
                ),
                if (info != null && info.total > 0) ...[
                  const SizedBox(height: 6),
                  SubscriptionInfoView(subscriptionInfo: info),
                ],
              ],
            ),
          ),
          if (profile != null && profile.type == ProfileType.url)
            DashboardIconButton(
              glyph: AppGlyphs.sync,
              tooltip: appLocalizations.update,
              onPressed: () => ref
                  .read(profilesActionProvider.notifier)
                  .updateProfile(profile, showLoading: true),
            ),
          if (switchable)
            DashboardIconButton(
              glyph: AppGlyphs.swap,
              tooltip: appLocalizations.switchProfile,
              onPressed: () => showProfilesSheet(context),
            ),
        ],
      ),
    );
  }
}
