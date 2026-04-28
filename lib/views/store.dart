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
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    try {
      final authStore = AuthStore();
      await authStore.init();
      final baseUrl = authStore.panelUrl;
      final authData = authStore.authData;

      if (baseUrl == null || authData == null) {
        setState(() {
          _error = '请先登录';
          _loading = false;
        });
        return;
      }

      final plans = await v2BoardClient.fetchPlans(baseUrl, authData);
      if (mounted) {
        setState(() {
          _plans = plans;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('商店'),
        centerTitle: true,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Colors.grey)),
            SizedBox(height: 16),
            OutlinedButton(onPressed: _loadPlans, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_plans.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storefront, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('暂无可用套餐', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _plans.length,
      itemBuilder: (_, index) => _PlanCard(plan: _plans[index]),
    );
  }
}

class _PlanCard extends StatefulWidget {
  final Map<String, dynamic> plan;
  const _PlanCard({required this.plan});

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> {
  bool _expanded = false;

  Map<String, dynamic> get plan => widget.plan;

  String _formatTraffic(dynamic val) {
    final v = (val is int) ? val : int.tryParse('$val') ?? 0;
    if (v <= 0) return '无限制';
    return '$v GB';
  }

  String _priceText(dynamic price) {
    if (price == null || price == 0) return '';
    final p = (price is num) ? price / 100.0 : 0;
    return '¥${p.toStringAsFixed(2)}';
  }

  List<MapEntry<String, String>> _availablePeriods() {
    final all = {
      'month_price': '月付',
      'quarter_price': '季付',
      'half_year_price': '半年',
      'year_price': '年付',
      'two_year_price': '两年',
      'three_year_price': '三年',
      'onetime_price': '一次性',
    };
    return all.entries
        .where((e) {
          final v = plan[e.key];
          return v != null && v is num && v > 0;
        })
        .toList();
  }

  Future<void> _handleBuy() async {
    final periods = _availablePeriods();
    if (periods.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该套餐暂无可用周期')),
        );
      }
      return;
    }

    // 1. 选择周期
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择购买周期'),
        children: periods.map((e) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, e.key),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(e.value),
                Text(
                  _priceText(plan[e.key]),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (selected == null || !mounted) return;

    // 2. 创建订单（自动取消旧订单）
    final authStore = AuthStore();
    await authStore.init();
    final baseUrl = authStore.panelUrl;
    final authData = authStore.authData;

    if (baseUrl == null || authData == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先登录')),
        );
      }
      return;
    }

    // 显示加载
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('正在下单...'),
          ]),
          duration: Duration(seconds: 30),
        ),
      );
    }

    String? tradeNo;
    try {
      final order = await v2BoardClient.createOrder(
        baseUrl,
        authData,
        planId: plan['id'],
        period: selected,
      );
      tradeNo = order['data']?.toString() ?? '';
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下单失败: $e')),
        );
      }
      return;
    }

    if (tradeNo.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下单失败: 未知错误')),
        );
      }
      return;
    }

    // 3. 获取支付方式
    List<Map<String, dynamic>> methods;
    try {
      methods = await v2BoardClient.getPaymentMethods(baseUrl, authData);
    } catch (_) {
      methods = [];
    }

    // 4. 选择支付方式
    if (methods.isEmpty) {
      // 无支付方式，可能免费或直接完成
      try {
        final result = await v2BoardClient.checkout(
          baseUrl, authData,
          tradeNo: tradeNo, method: 0,
        );
        final type = result['type'];
        if (type == -1) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('购买成功！')),
            );
          }
        }
      } catch (_) {}
      return;
    }

    if (!mounted) return;
    final methodId = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择支付方式'),
        children: methods.map((m) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, m['id']),
            child: Row(
              children: [
                if (m['icon'] != null) ...[
                  Image.network(m['icon'], width: 24, height: 24, errorBuilder: (_, __, ___) => Icon(Icons.payment, size: 24)),
                  SizedBox(width: 12),
                ],
                Text(m['name'] ?? ''),
              ],
            ),
          );
        }).toList(),
      ),
    );

    if (methodId == null || !mounted) return;

    // 5. 获取支付链接
    try {
      final result = await v2BoardClient.checkout(
        baseUrl, authData,
        tradeNo: tradeNo, method: methodId,
      );
      final type = result['type'];
      final data = result['data'];

      if (mounted) {
        if (type == -1) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('购买成功！')),
          );
        } else {
          final payUrl = (data is String) ? data : data.toString();
          if (type == 1 && payUrl.isNotEmpty) {
            // 跳转到外部支付页面
            launchUrl(Uri.parse(payUrl), mode: LaunchMode.externalApplication);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已打开支付页面，请在浏览器中完成支付')),
            );
          } else {
            // 显示二维码或支付链接
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('请完成支付'),
                content: SelectableText(payUrl),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取支付信息失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = plan['name'] ?? '';
    final traffic = plan['transfer_enable'];
    final deviceLimit = plan['device_limit'];
    final speedLimit = plan['speed_limit'];
    final monthPrice = plan['month_price'];
    final content = plan['content'] as String?;
    final cleanContent = content?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '$name',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (monthPrice != null && monthPrice > 0)
                  Text(
                    _priceText(monthPrice) + '/月',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
              ],
            ),
            SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _InfoChip(icon: Icons.data_usage, label: _formatTraffic(traffic)),
                if (deviceLimit != null && deviceLimit > 0)
                  _InfoChip(icon: Icons.devices, label: '$deviceLimit 设备'),
                if (deviceLimit == null || deviceLimit == 0)
                  _InfoChip(icon: Icons.devices, label: '无限设备'),
                if (speedLimit != null && speedLimit > 0)
                  _InfoChip(icon: Icons.speed, label: '$speedLimit Mbps'),
                if (speedLimit == null || speedLimit == 0)
                  _InfoChip(icon: Icons.speed, label: '不限速'),
              ],
            ),
            if (cleanContent.isNotEmpty) ...[
              SizedBox(height: 8),
              Text(
                cleanContent,
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? '收起' : '展开详情',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ],
            SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: _availablePeriods()
                  .map((e) => Text(
                        '${e.value} ${_priceText(plan[e.key])}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ))
                  .toList(),
            ),
            SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _handleBuy,
                child: const Text('购买'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey),
        SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }
}
