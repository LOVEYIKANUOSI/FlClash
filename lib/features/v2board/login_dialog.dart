import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:flutter/material.dart';

import 'client.dart';


Future<void> showV2BoardLoginAndImport() async {
  final url = await globalState.showCommonDialog<String>(
    child: const V2BoardLoginDialog(),
  );
  if (url != null) {
    appController.addProfileFormURL(url);
  }
}

class V2BoardLoginDialog extends StatefulWidget {
  const V2BoardLoginDialog({super.key});

  @override
  State<V2BoardLoginDialog> createState() => _V2BoardLoginDialogState();
}

class _V2BoardLoginDialogState extends State<V2BoardLoginDialog> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController(text: 'http://localhost');
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorText;

  Future<void> _handleSubmit() async {
    if (_isSubmitting || _formKey.currentState?.validate() == false) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });
    try {
      final subscribeUrl = await v2BoardClient.loginAndGetSubscribeUrl(
        V2BoardCredentials(
          baseUrl: _baseUrlController.text,
          email: _emailController.text,
          password: _passwordController.text,
        ),
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop<String>(subscribeUrl);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommonDialog(
      title: 'V2Board 登录',
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : _handleSubmit,
          child: Text(_isSubmitting ? '连接中...' : appLocalizations.submit),
        ),
      ],
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Wrap(
          runSpacing: 16,
          children: [
            TextFormField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '面板地址',
                hintText: 'https://panel.example.com',
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) {
                  return '请输入面板地址';
                }
                if (!text.isUrl) {
                  return '请输入完整地址';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '邮箱',
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) {
                  return '请输入邮箱';
                }
                if (!text.contains('@')) {
                  return '邮箱格式不正确';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '密码',
              ),
              onFieldSubmitted: (_) {
                _handleSubmit();
              },
              validator: (value) {
                final text = value ?? '';
                if (text.isEmpty) {
                  return '请输入密码';
                }
                return null;
              },
            ),
            if (_errorText != null)
              Text(
                _errorText!,
                style: TextStyle(color: context.colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
