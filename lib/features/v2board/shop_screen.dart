import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

const _periodLabels = <String, String>{
  'month_price': '月付',
  'quarter_price': '季付',
  'half_year_price': '半年',
  'year_price': '年付',
  'two_year_price': '两年',
  'three_year_price': '三年',
  'onetime_price': '一次性',
};

/// 商城页：展示当前订阅状态 + 可购买套餐，走面板的下单/支付流程。
class V2BoardShopView extends StatefulWidget {
  const V2BoardShopView({super.key});

  @override
  State<V2BoardShopView> createState() => _V2BoardShopViewState();
}

class _V2BoardShopViewState extends State<V2BoardShopView> {
  final AuthStore _authStore = AuthStore();
  List<Map<String, dynamic>> _plans = const [];
  Map<String, dynamic>? _userInfo;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _authStore.init();
      final baseUrl = _authStore.apiBaseUrl;
      final authData = _authStore.authData;
      if (authData == null) {
        if (mounted) {
          setState(() {
            _error = '登录信息已失效，请重新登录';
            _loading = false;
          });
        }
        return;
      }
      final plans = await v2BoardClient.fetchPlans(baseUrl, authData);
      final userInfo = await v2BoardClient.getUserInfo(baseUrl, authData);
      if (mounted) {
        setState(() {
          _plans = plans;
          _userInfo = userInfo;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<String?> _pickPeriod(Map<String, dynamic> plan) {
    final options = [
      for (final entry in _periodLabels.entries)
        if (plan[entry.key] is num && (plan[entry.key] as num) > 0)
          (key: entry.key, label: entry.value, price: plan[entry.key] as num),
    ];
    if (options.isEmpty) {
      return Future.value(null);
    }
    return showSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text(
              '选择购买周期',
              style: AppTextStyle.headline.of(context, emphasized: true),
            ),
            const SizedBox(height: 8),
            for (final option in options)
              ListItem(
                title: Text(option.label),
                trailing: Text(_formatYuan(option.price)),
                onTap: () => Navigator.of(context).pop(option.key),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<int?> _pickMethod(List<Map<String, dynamic>> methods) {
    return showSheet<int>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text(
              '选择支付方式',
              style: AppTextStyle.headline.of(context, emphasized: true),
            ),
            const SizedBox(height: 8),
            for (final method in methods)
              ListItem(
                leading: const GlyphIcon(AppGlyphs.account),
                title: Text('${method['name'] ?? ''}'),
                onTap: () => Navigator.of(context).pop(
                  (method['id'] as num?)?.toInt() ?? 0,
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _buy(Map<String, dynamic> plan) async {
    final period = await _pickPeriod(plan);
    if (period == null || !mounted) {
      return;
    }
    final baseUrl = _authStore.apiBaseUrl;
    final authData = _authStore.authData;
    final planId = (plan['id'] as num?)?.toInt();
    if (authData == null || planId == null) {
      return;
    }
    try {
      final tradeNo = await v2BoardClient.createOrder(
        baseUrl,
        authData,
        planId: planId,
        period: period,
      );
      final methods = await v2BoardClient.getPaymentMethods(baseUrl, authData);
      if (!mounted) {
        return;
      }
      if (methods.isEmpty) {
        final result = await v2BoardClient.checkout(
          baseUrl,
          authData,
          tradeNo: tradeNo,
          method: 0,
        );
        if ((result['type'] as num?)?.toInt() == -1) {
          dialogs.showBanner('购买成功');
          await _loadData();
        } else {
          dialogs.showBanner('订单已创建，请在面板网页完成支付');
        }
        return;
      }
      final methodId = await _pickMethod(methods);
      if (methodId == null || !mounted) {
        return;
      }
      final result = await v2BoardClient.checkout(
        baseUrl,
        authData,
        tradeNo: tradeNo,
        method: methodId,
      );
      if ((result['type'] as num?)?.toInt() == -1) {
        dialogs.showBanner('购买成功');
        await _loadData();
        return;
      }
      final data = result['data'];
      if (data is String && data.isNotEmpty) {
        await launchUrl(Uri.parse(data), mode: LaunchMode.externalApplication);
        dialogs.showBanner('已打开支付页面');
      } else {
        dialogs.showBanner('订单已创建，请在面板网页完成支付');
      }
    } catch (e) {
      dialogs.showBanner('$e', level: BannerLevel.error);
    }
  }

  Future<void> _resetTraffic() async {
    final baseUrl = _authStore.apiBaseUrl;
    final authData = _authStore.authData;
    final plan = _userInfo?['plan'];
    if (authData == null || plan is! Map) {
      return;
    }
    final resetPrice = (plan['reset_price'] as num?)?.toInt() ?? 0;
    final planId = (plan['id'] as num?)?.toInt();
    if (planId == null || resetPrice <= 0) {
      dialogs.showBanner('当前套餐不支持流量重置');
      return;
    }
    final confirmed = await dialogs.showMessage(
      message: TextSpan(
        text: '重置后本周期已用流量清零，费用 ${_formatYuan(resetPrice)}。',
      ),
      title: '重置流量',
      confirmText: '确定重置',
      cancelText: '取消',
    );
    if (confirmed != true) {
      return;
    }
    try {
      final tradeNo = await v2BoardClient.createOrder(
        baseUrl,
        authData,
        planId: planId,
        period: 'reset_price',
      );
      final result = await v2BoardClient.checkout(
        baseUrl,
        authData,
        tradeNo: tradeNo,
        method: 0,
      );
      if ((result['type'] as num?)?.toInt() == -1) {
        dialogs.showBanner('流量已重置');
      } else {
        dialogs.showBanner('重置订单已创建，请在面板网页完成支付');
      }
      await _loadData();
    } catch (e) {
      dialogs.showBanner('$e', level: BannerLevel.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: '商城',
      body: _loading
          ? const Center(child: ActivityIndicator())
          : _error != null
          ? _ShopError(message: _error!, onRetry: _loadData)
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                context.contentTopPadding,
                16,
                32,
              ),
              children: [
                if (_userInfo != null) ...[
                  _SubscriptionBanner(
                    userInfo: _userInfo!,
                    onReset: _resetTraffic,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_plans.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: Text('暂无可用套餐')),
                  )
                else
                  for (final plan in _plans)
                    _PlanCard(plan: plan, onBuy: () => _buy(plan)),
              ],
            ),
    );
  }
}

class _ShopError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ShopError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlyphIcon(AppGlyphs.account, size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyle.subheadline.of(
                context,
              ).copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionBanner extends StatelessWidget {
  final Map<String, dynamic> userInfo;
  final VoidCallback onReset;

  const _SubscriptionBanner({required this.userInfo, required this.onReset});

  int _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('$value') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final plan = userInfo['plan'];
    final planName = plan is Map ? '${plan['name'] ?? '无订阅'}' : '无订阅';
    final total = _asInt(userInfo['transfer_enable']);
    final used = _asInt(userInfo['u']) + _asInt(userInfo['d']);
    final expiredAt = _asInt(userInfo['expired_at']);
    final resetPrice = plan is Map ? _asInt(plan['reset_price']) : 0;
    final progress = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final expireText = expiredAt <= 0
        ? '长期有效'
        : DateTime.fromMillisecondsSinceEpoch(
            expiredAt * 1000,
          ).toString().substring(0, 10);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GlyphIcon(AppGlyphs.verified, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  planName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.headline.of(context, emphasized: true),
                ),
              ),
              if (resetPrice > 0)
                TonalButton(
                  size: TonalButtonSize.section,
                  glyph: AppGlyphs.refresh,
                  label: '重置流量',
                  onPressed: onReset,
                ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_formatBytes(used)} / ${_formatBytes(total)}',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '到期 $expireText',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  final VoidCallback onBuy;

  const _PlanCard({required this.plan, required this.onBuy});

  int _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('$value') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final name = '${plan['name'] ?? ''}';
    final traffic = _asInt(plan['transfer_enable']);
    final deviceLimit = _asInt(plan['device_limit']);
    final speedLimit = _asInt(plan['speed_limit']);
    final content = (plan['content'] as String?)
            ?.replaceAll(RegExp(r'<[^>]*>'), '')
            .trim() ??
        '';
    final periods = [
      for (final entry in _periodLabels.entries)
        if (plan[entry.key] is num && (plan[entry.key] as num) > 0)
          (label: entry.value, price: plan[entry.key] as num),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppTextStyle.title3.of(context, emphasized: true),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        _Tag(label: '${traffic}GB 流量'),
                        _Tag(
                          label: deviceLimit > 0 ? '$deviceLimit 台设备' : '不限设备',
                        ),
                        if (speedLimit > 0) _Tag(label: '$speedLimit Mbps'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (content.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (periods.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                for (final period in periods)
                  Text(
                    '${period.label} ${_formatYuan(period.price)}',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: periods.isEmpty ? null : onBuy,
              child: const Text('购买'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;

  const _Tag({required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

String _formatYuan(num cents) => '¥${(cents / 100).toStringAsFixed(2)}';

String _formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 2)} ${units[index]}';
}
