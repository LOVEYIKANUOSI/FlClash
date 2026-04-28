import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';

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

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  const _PlanCard({required this.plan});

  String _formatTraffic(dynamic bytes) {
    final b = (bytes is int) ? bytes : int.tryParse('$bytes') ?? 0;
    if (b <= 0) return '无限制';
    final gb = b / 1073741824;
    return '${gb.toStringAsFixed(0)} GiB';
  }

  String _priceText(dynamic price) {
    if (price == null) return '——';
    final p = (price is num) ? price / 100 : 0;
    return '¥${p.toStringAsFixed(2)}';
  }

  Widget _buildPriceRow() {
    final labels = {
      'month_price': '月付',
      'quarter_price': '季付',
      'half_year_price': '半年',
      'year_price': '年付',
    };
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: labels.entries
          .where((e) => plan[e.key] != null && plan[e.key] > 0)
          .map((e) => Text(
                '${e.value} ${_priceText(plan[e.key])}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ))
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = plan['name'] ?? 'Unknown';
    final traffic = plan['transfer_enable'];
    final deviceLimit = plan['device_limit'];
    final speedLimit = plan['speed_limit'];
    final monthPrice = plan['month_price'];

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
                if (monthPrice != null)
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
            Row(
              children: [
                _InfoChip(icon: Icons.data_usage, label: _formatTraffic(traffic)),
                SizedBox(width: 12),
                if (deviceLimit != null && deviceLimit > 0)
                  _InfoChip(icon: Icons.devices, label: '$deviceLimit 设备'),
                if (speedLimit != null && speedLimit > 0) ...[
                  SizedBox(width: 12),
                  _InfoChip(
                    icon: Icons.speed,
                    label: '${(speedLimit / 1048576).toStringAsFixed(0)} Mbps',
                  ),
                ],
              ],
            ),
            SizedBox(height: 8),
            _buildPriceRow(),
            SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {},
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
