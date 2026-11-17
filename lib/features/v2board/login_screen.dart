import 'package:fl_clash/features/v2board/app_config.dart';
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
  String? _localError;

  @override
  void initState() {
    super.initState();
    _panelController = TextEditingController(
      text: v2BoardState.panelUrl,
    );
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
                      hintText: '面板地址，例如 ${AppConfig.defaultPanelUrl}',
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
                  const SizedBox(height: 24),
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
