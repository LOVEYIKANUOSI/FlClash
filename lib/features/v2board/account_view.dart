import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:fl_clash/features/v2board/v2board_state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

/// Dawn 账户页：展示登录态/设备/域名池，并提供刷新订阅、心跳、探测、登出。
class V2BoardAccountView extends StatefulWidget {
  const V2BoardAccountView({super.key});

  @override
  State<V2BoardAccountView> createState() => _V2BoardAccountViewState();
}

class _V2BoardAccountViewState extends State<V2BoardAccountView> {
  final AuthStore _authStore = AuthStore();
  Map<String, dynamic>? _userInfo;

  @override
  void initState() {
    super.initState();
    v2BoardState.addListener(_handleStateChanged);
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    try {
      await _authStore.init();
      final authData = _authStore.authData;
      if (authData == null) {
        return;
      }
      final userInfo = await v2BoardClient.getUserInfo(
        _authStore.apiBaseUrl,
        authData,
      );
      if (mounted) {
        setState(() => _userInfo = userInfo);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    v2BoardState.removeListener(_handleStateChanged);
    super.dispose();
  }

  void _handleStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  String _heartbeatLabel() {
    final at = v2BoardState.lastHeartbeatAt;
    if (at == null) {
      return '尚未上报';
    }
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    return '${v2BoardState.lastHeartbeatOk ? '正常' : '失败'} · $hh:$mm:$ss';
  }

  int _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('$value') ?? 0;
  }

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

  List<Widget> _subscriptionItems() {
    final userInfo = _userInfo;
    if (userInfo == null) {
      return [
        _infoTile(
          glyph: AppGlyphs.verified,
          title: '订阅信息',
          subtitle: '加载中或暂不可用',
        ),
      ];
    }
    final plan = userInfo['plan'];
    final planName = plan is Map ? '${plan['name'] ?? '无订阅'}' : '无订阅';
    final total = _asInt(userInfo['transfer_enable']);
    final used = _asInt(userInfo['u']) + _asInt(userInfo['d']);
    final remaining = (total - used).clamp(0, total);
    final expiredAt = _asInt(userInfo['expired_at']);
    final expireText = expiredAt <= 0
        ? '长期有效'
        : DateTime.fromMillisecondsSinceEpoch(
            expiredAt * 1000,
          ).toString().substring(0, 10);
    return [
      _infoTile(
        glyph: AppGlyphs.verified,
        title: planName,
        subtitle: '到期 $expireText',
      ),
      _infoTile(
        glyph: AppGlyphs.dataUsage,
        title: '剩余流量',
        subtitle: '${_formatBytes(remaining)} / ${_formatBytes(total)}',
      ),
      _infoTile(
        glyph: AppGlyphs.cloudDownload,
        title: '已用流量',
        subtitle: _formatBytes(used),
      ),
    ];
  }

  Widget _infoTile({
    required Glyph glyph,
    required String title,
    required String subtitle,
  }) {
    return ListItem(
      leading: GlyphIcon(glyph),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _actionTile({
    required Glyph glyph,
    required String label,
    VoidCallback? onPressed,
  }) {
    return ListItem(
      leading: GlyphIcon(glyph),
      title: Text(label),
      trailing: const GlyphIcon(AppGlyphs.chevronForward),
      onTap: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = v2BoardState;
    final colorScheme = context.colorScheme;
    final pool = state.domainPool;
    return Scaffold(
      title: 'Dawn 账户',
      isLoading: state.busy,
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          generateSection(
            title: '订阅',
            items: _subscriptionItems(),
          ),
          generateSection(
            items: [
              _infoTile(
                glyph: AppGlyphs.profiles,
                title: state.email.isEmpty ? '未登录' : state.email,
                subtitle: '面板：${state.panelUrl}',
              ),
              _infoTile(
                glyph: AppGlyphs.dns,
                title: '当前域名',
                subtitle: state.activeDomain.isEmpty
                    ? '未下发'
                    : state.activeDomain,
              ),
              _infoTile(
                glyph: AppGlyphs.target,
                title: '设备 ID',
                subtitle: state.deviceId.isEmpty ? '未注册' : state.deviceId,
              ),
              _infoTile(
                glyph: AppGlyphs.clock,
                title: '心跳',
                subtitle:
                    '每 ${state.heartbeatIntervalSeconds}s · ${_heartbeatLabel()}',
              ),
              _infoTile(
                glyph: AppGlyphs.resources,
                title: '域名池',
                subtitle: pool.isEmpty ? '未下发（使用面板地址）' : pool.join('、'),
              ),
            ],
          ),
          if (state.notice != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                state.notice!,
                style: AppTextStyle.subheadline
                    .of(context)
                    .copyWith(color: colorScheme.primary),
              ),
            ),
          ],
          if (state.lastError != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                state.lastError!,
                style: AppTextStyle.subheadline
                    .of(context)
                    .copyWith(color: colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: 12),
          generateSection(
            title: '操作',
            items: [
              _actionTile(
                glyph: AppGlyphs.sync,
                label: '刷新专属订阅',
                onPressed: state.busy
                    ? null
                    : () {
                        state.refreshSubscribe();
                        _loadUserInfo();
                      },
              ),
              _actionTile(
                glyph: AppGlyphs.cpu,
                label: '刷新设备信息（环境画像）',
                onPressed: state.busy ? null : state.refreshDevice,
              ),
              _actionTile(
                glyph: AppGlyphs.refresh,
                label: '立即心跳',
                onPressed: state.busy ? null : state.heartbeatNow,
              ),
              _actionTile(
                glyph: AppGlyphs.dns,
                label: '立即探测并切换域名',
                onPressed: state.busy ? null : state.probeNow,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TonalButton(
              size: TonalButtonSize.bar,
              glyph: AppGlyphs.block,
              label: '退出登录',
              onPressed: state.busy ? null : state.logout,
            ),
          ),
        ],
      ),
    );
  }
}
