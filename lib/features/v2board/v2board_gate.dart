import 'dart:async';

import 'package:fl_clash/features/v2board/login_screen.dart';
import 'package:fl_clash/features/v2board/v2board_state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

/// 登录门禁：包住整个 App 主界面，未登录时只显示登录页。
class V2BoardGate extends StatefulWidget {
  final Widget child;

  const V2BoardGate({super.key, required this.child});

  @override
  State<V2BoardGate> createState() => _V2BoardGateState();
}

class _V2BoardGateState extends State<V2BoardGate> {
  @override
  void initState() {
    super.initState();
    unawaited(v2BoardState.init());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: v2BoardState,
      builder: (context, _) {
        if (!v2BoardState.initialized) {
          return _Splash();
        }
        if (!v2BoardState.hasSession) {
          return const V2BoardLoginScreen();
        }
        return widget.child;
      },
    );
  }
}

class _Splash extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Dawn',
              style: AppTextStyle.largeTitle.of(context, emphasized: true),
            ),
            if (v2BoardState.autoLoginRunning) ...[
              const SizedBox(height: 12),
              Text(
                '正在自动登录…',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
