import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:url_launcher/url_launcher.dart';

class StoreView extends ConsumerStatefulWidget {
  const StoreView({super.key});

  @override
  ConsumerState<StoreView> createState() => _StoreViewState();
}

class _StoreViewState extends ConsumerState<StoreView> {
  List<Map<String, dynamic>> _plans = [];
  Map<String, dynamic>? _userInfo;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final authStore = AuthStore();
      await authStore.init();
      final baseUrl = authStore.panelUrl;
      final authData = authStore.authData;

      if (baseUrl == null || authData == null) {
        setState(() { _error = '请先登录'; _loading = false; });
        return;
      }

      final results = await Future.wait([
        v2BoardClient.fetchPlans(baseUrl, authData),
        v2BoardClient.getUserInfo(baseUrl, authData),
      ]);
      if (mounted) {
        setState(() {
          _plans = results[0] as List<Map<String, dynamic>>;
          _userInfo = results[1] as Map<String, dynamic>?;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _resetTraffic() async {
    final plan = _userInfo?['plan'] as Map<String, dynamic>?;
    if (plan == null) return;

    final resetPrice = plan['reset_price'];
    if (resetPrice == null || resetPrice == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前套餐不支持流量重置')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置流量'),
        content: Text('确定要重置流量吗？费用：¥${(resetPrice / 100).toStringAsFixed(2)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final authStore = AuthStore();
    await authStore.init();

    try {
      final order = await v2BoardClient.createOrder(
        authStore.panelUrl!, authStore.authData!,
        planId: plan['id'], period: 'reset_price',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重置订单已创建: ${order['data']}\n请在订单页面完成支付')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重置失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('商店'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.storefront_outlined, size: 56, color: cs.outline),
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: cs.outline)),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(onPressed: _loadData, icon: const Icon(Icons.refresh, size: 18), label: const Text('重试')),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _plans.length + (_userInfo != null ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (_userInfo != null && i == 0) {
                        return _SubscriptionBanner(userInfo: _userInfo!, onReset: _resetTraffic);
                      }
                      final pi = _userInfo != null ? i - 1 : i;
                      return _PlanCard(plan: _plans[pi], index: pi);
                    },
                  ),
                ),
    );
  }
}

// ========== 订阅信息卡片 ==========
class _SubscriptionBanner extends StatelessWidget {
  final Map<String, dynamic> userInfo;
  final VoidCallback onReset;
  const _SubscriptionBanner({required this.userInfo, required this.onReset});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final plan = userInfo['plan'] as Map<String, dynamic>?;
    final planName = plan?['name'] ?? '无订阅';
    final total = userInfo['transfer_enable'] ?? 0;
    final used = (userInfo['u'] ?? 0) + (userInfo['d'] ?? 0);
    final progress = (total > 0) ? ((used as num) / (total as num)).clamp(0.0, 1.0) : 0.0;
    final resetPrice = plan?['reset_price'];
    final expiredAt = userInfo['expired_at'];

    String fmt(dynamic v) {
      final n = (v is int) ? v : int.tryParse('$v') ?? 0;
      return n > 0 ? '${(n / 1073741824).toStringAsFixed(1)} GB' : '0 GB';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.card_membership, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(planName, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            if (resetPrice != null && resetPrice > 0)
              TextButton.icon(onPressed: onReset, icon: const Icon(Icons.refresh, size: 16), label: const Text('重置流量', style: TextStyle(fontSize: 13))),
          ]),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: progress, minHeight: 8, borderRadius: BorderRadius.circular(4), backgroundColor: cs.primary.withOpacity(0.12)),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${fmt(used)} / ${fmt(total)}', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            if (expiredAt != null && expiredAt > 0)
              Text('到期 ${DateTime.fromMillisecondsSinceEpoch(expiredAt * 1000).toString().substring(0, 10)}', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ]),
        ]),
      ),
    );
  }
}

// ========== 套餐卡片 ==========
class _PlanCard extends StatefulWidget {
  final Map<String, dynamic> plan;
  final int index;
  const _PlanCard({required this.plan, required this.index});

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> {
  bool _expanded = false;
  Map<String, dynamic> get plan => widget.plan;

  List<_PeriodOption> _getPeriods() {
    const labels = {'month_price': '月付', 'quarter_price': '季付', 'half_year_price': '半年', 'year_price': '年付', 'two_year_price': '两年', 'three_year_price': '三年', 'onetime_price': '一次性'};
    return labels.entries.where((e) => plan[e.key] != null && plan[e.key] is num && plan[e.key] > 0).map((e) => _PeriodOption(key: e.key, label: e.value, price: plan[e.key])).toList();
  }

  String fmtPrice(dynamic price) => '¥${((price as num) / 100.0).toStringAsFixed(2)}';

  Future<void> _handleBuy() async {
    final periods = _getPeriods();
    if (periods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该套餐暂无可用周期')));
      return;
    }

    final selected = await showModalBottomSheet<String>(context: context, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => _PeriodPicker(periods: periods));
    if (selected == null || !mounted) return;

    final authStore = AuthStore();
    await authStore.init();
    final baseUrl = authStore.panelUrl;
    final authData = authStore.authData;
    if (baseUrl == null || authData == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先登录'))); return; }

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Row(children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 12), Text('正在下单...')]), duration: Duration(seconds: 30)));

    try {
      final order = await v2BoardClient.createOrder(baseUrl, authData, planId: plan['id'], period: selected);
      final tradeNo = order['data']?.toString() ?? '';
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (tradeNo.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('下单失败'))); return; }

      final methods = await v2BoardClient.getPaymentMethods(baseUrl, authData);

      if (methods.isEmpty) {
        final r = await v2BoardClient.checkout(baseUrl, authData, tradeNo: tradeNo, method: 0);
        if ((r['type'] ?? 0) == -1 && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('购买成功！')));
        return;
      }

      if (!mounted) return;
      final methodId = await showModalBottomSheet<int>(context: context, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => _MethodPicker(methods: methods));
      if (methodId == null || !mounted) return;

      final r = await v2BoardClient.checkout(baseUrl, authData, tradeNo: tradeNo, method: methodId);
      final data = r['data'];

      if (!mounted) return;
      if (r['type'] == -1) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('购买成功！')));
      } else if (data is String && data.isNotEmpty) {
        launchUrl(Uri.parse(data), mode: LaunchMode.externalApplication);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已打开支付页面')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('支付信息: $data')));
      }
    } catch (e) {
      if (mounted) { ScaffoldMessenger.of(context).hideCurrentSnackBar(); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = plan['name'] ?? '';
    final traffic = plan['transfer_enable'];
    final deviceLimit = plan['device_limit'];
    final speedLimit = plan['speed_limit'];
    final monthPrice = plan['month_price'];
    final content = (plan['content'] as String?)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
    final promoted = widget.index == 1;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                if (promoted) ...[const SizedBox(width: 8), Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(4)), child: Text('推荐', style: TextStyle(fontSize: 11, color: cs.onPrimary, fontWeight: FontWeight.w600)))],
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 10, runSpacing: 4, children: [
                _Tag(icon: Icons.data_usage_outlined, label: '${traffic ?? 0} GB'),
                _Tag(icon: Icons.devices_other, label: (deviceLimit != null && deviceLimit > 0) ? '$deviceLimit 设备' : '无限设备'),
                if (speedLimit != null && speedLimit > 0) _Tag(icon: Icons.speed, label: '$speedLimit Mbps'),
              ]),
            ])),
            if (monthPrice != null && monthPrice > 0)
              Text(fmtPrice(monthPrice) + '/月', style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w800)),
          ]),
          if (content.isNotEmpty) ...[
            const SizedBox(height: 12),
            AnimatedCrossFade(
              firstChild: Text(content, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.5)),
              secondChild: Text(content, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.5)),
              crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
            GestureDetector(onTap: () => setState(() => _expanded = !_expanded), child: Padding(padding: const EdgeInsets.only(top: 4), child: Text(_expanded ? '收起详情 ▲' : '展开详情 ▼', style: TextStyle(fontSize: 13, color: cs.primary, fontWeight: FontWeight.w500)))),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 14, runSpacing: 4, children: _getPeriods().map((p) => Text('${p.label} ${fmtPrice(p.price)}', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, fontWeight: FontWeight.w500))).toList()),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, height: 44, child: FilledButton(onPressed: _handleBuy, style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: const Text('购买', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)))),
        ]),
      ),
    );
  }
}

// ========== 小标签 ==========
class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Tag({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 13, color: cs.onSurfaceVariant), const SizedBox(width: 4), Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))]));
  }
}

// ========== 周期选择底部弹窗 ==========
class _PeriodPicker extends StatelessWidget {
  final List<_PeriodOption> periods;
  const _PeriodPicker({required this.periods});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      Container(width: 36, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2))),
      const SizedBox(height: 16),
      Text('选择购买周期', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      ...periods.map((p) => ListTile(title: Text(p.label), trailing: Text(p.key == 'onetime_price' ? '¥${((p.price as num) / 100.0).toStringAsFixed(2)}' : '¥${((p.price as num) / 100.0).toStringAsFixed(2)}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)), onTap: () => Navigator.pop(context, p.key))),
      const SizedBox(height: 8),
    ]));
  }
}

// ========== 支付方式底部弹窗 ==========
class _MethodPicker extends StatelessWidget {
  final List<Map<String, dynamic>> methods;
  const _MethodPicker({required this.methods});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      Container(width: 36, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2))),
      const SizedBox(height: 16),
      Text('选择支付方式', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      ...methods.map((m) => ListTile(leading: const Icon(Icons.payment), title: Text(m['name'] ?? ''), onTap: () => Navigator.pop(context, m['id']))),
      const SizedBox(height: 8),
    ]));
  }
}

class _PeriodOption { final String key, label; final dynamic price; const _PeriodOption({required this.key, required this.label, required this.price}); }
