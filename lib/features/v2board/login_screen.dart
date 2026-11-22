import 'package:fl_clash/features/v2board/v2board_state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 登录门禁页：未登录时替换 HomePage 显示，登录成功后由 [V2BoardGate] 放行。
class V2BoardLoginScreen extends StatefulWidget {
  const V2BoardLoginScreen({super.key});

  @override
  State<V2BoardLoginScreen> createState() => _V2BoardLoginScreenState();
}

class _V2BoardLoginScreenState extends State<V2BoardLoginScreen> {
  late final TextEditingController _panelController;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  /// 是否勾选「自动登录」。默认勾上——用户反馈登录太频繁；
  /// 之前开启过的话也保持勾选状态一致。
  bool _autoLogin = true;

  String? _localError;

  @override
  void initState() {
    super.initState();
    _panelController = TextEditingController(
      text: v2BoardState.panelUrl,
    );
    _emailController.text = v2BoardState.email;
    _autoLogin = true;
    v2BoardState.addListener(_handleStateChanged);
  }

  @override
  void dispose() {
    v2BoardState.removeListener(_handleStateChanged);
    _panelController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final panel = _panelController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _localError = '请输入正确的邮箱');
      return;
    }
    if (password.isEmpty) {
      setState(() => _localError = '请输入密码');
      return;
    }
    if (panel.isEmpty) {
      setState(() => _localError = '请输入面板地址');
      return;
    }
    setState(() => _localError = null);
    v2BoardState.clearNotice();
    await v2BoardState.login(
      email: email,
      password: password,
      panelUrl: panel,
      autoLogin: _autoLogin,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final busy = v2BoardState.busy;
    final error = _localError ?? v2BoardState.lastError;
    return ColoredBox(
      color: colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Dawn',
                    textAlign: TextAlign.center,
                    style: AppTextStyle.largeTitle.of(context, emphasized: true),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请登录 Dawn 账号后使用',
                    textAlign: TextAlign.center,
                    style: AppTextStyle.subheadline.of(context).copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _panelController,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      // 源码不写真实生产入口（S-34）：只给一个明显是示例的占位符。
                      hintText: '面板地址（例如 https://panel.example.com）',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      hintText: '邮箱',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => busy ? null : _submit(),
                    decoration: const InputDecoration(
                      hintText: '密码',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: AppTextStyle.subheadline.of(context).copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _AutoLoginRow(
                    value: _autoLogin,
                    enabled: !busy,
                    expiresAt: v2BoardState.autoLoginExpiresAt,
                    onChanged: (value) => setState(() => _autoLogin = value),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy ? null : _submit,
                    child: Text(
                      busy ? '登录中…' : '登 录',
                      style: AppTextStyle.headline.of(context),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '登录后将自动完成设备注册、专属订阅导入与心跳上报',
                    textAlign: TextAlign.center,
                    style: AppTextStyle.caption1.of(context).copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「自动登录」勾选行：勾上后密码进系统加密存储，1 年内启动免输入。
class _AutoLoginRow extends StatelessWidget {
  const _AutoLoginRow({
    required this.value,
    required this.enabled,
    required this.expiresAt,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final DateTime? expiresAt;
  final ValueChanged<bool> onChanged;

  static String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final expiresAt = this.expiresAt;
    final hint = (value && expiresAt != null)
        ? '已加密保存在本机，${_formatDate(expiresAt)} 前无需再登录'
        : '勾选后密码加密保存在本机，1 年内启动无需再输入';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          value: value,
          onChanged: enabled ? (checked) => onChanged(checked ?? false) : null,
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => onChanged(!value) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '自动登录（1 年内免密）',
                  style: AppTextStyle.subheadline.of(context),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
