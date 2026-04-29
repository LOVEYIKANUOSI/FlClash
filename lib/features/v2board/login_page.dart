import 'dart:io';
import 'package:flutter/material.dart';

import 'auth_store.dart';
import 'client.dart';

const _defaultPanelUrl = 'https://adfdcvz4a9sef4191dsf1g51651v6s.jinriqifeionline.cc';

class LoginPage extends StatefulWidget {
  final AuthStore authStore;
  final VoidCallback? onLoginSuccess;

  const LoginPage({super.key, required this.authStore, this.onLoginSuccess});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (_isLoading || _formKey.currentState?.validate() == false) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final subscribeUrl = await v2BoardClient.loginAndGetSubscribeUrl(
        V2BoardCredentials(
          baseUrl: _defaultPanelUrl,
          email: _emailController.text.trim(),
          password: _passwordController.text,
        ),
      );

      if (!mounted) return;

      await widget.authStore.save(
        panelUrl: _defaultPanelUrl,
        email: _emailController.text.trim(),
        authData: v2BoardClient.lastAuthData ?? '',
        token: v2BoardClient.lastToken ?? '',
        subscribeUrl: subscribeUrl,
      );

      print('[LoginPage] saved auth: hasSession=${widget.authStore.hasSession} panelUrl=${widget.authStore.panelUrl?.substring(0, 20)}...');

      if (!mounted) return;

      widget.onLoginSuccess?.call();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      // 输出到 Flutter 控制台方便排查
      print('[LoginPage] 登录失败: $msg');
      setState(() {
        _errorText = msg;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          exit(0);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('FlClash'),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.vpn_lock_rounded,
                        size: 64,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '请登录以继续使用',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '邮箱',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: (v) {
                          final text = v?.trim() ?? '';
                          if (text.isEmpty) return '请输入邮箱';
                          if (!text.contains('@')) return '邮箱格式不正确';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '密码',
                          prefixIcon: Icon(Icons.lock_outlined),
                        ),
                        onFieldSubmitted: (_) => _handleLogin(),
                        validator: (v) {
                          if ((v ?? '').isEmpty) return '请输入密码';
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      if (_errorText != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            _errorText!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      FilledButton(
                        onPressed: _isLoading ? null : _handleLogin,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('登 录', style: TextStyle(fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
