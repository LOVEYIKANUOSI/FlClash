import 'package:fl_clash/common/preferences.dart';

/// 高级模式开关。
///
/// 关闭（默认）时侧边栏只保留仪表盘/代理/商城/公告/工单/账户/工具，
/// 配置、请求、资源、DNS 这些偏开发者入口收起来；工具页的开关可一键打开。
class HiddenItems {
  HiddenItems._();

  static bool show = false;

  static Future<void> init() async {
    show = await preferences.getShowHidden();
  }

  static Future<void> set(bool value) async {
    show = value;
    await preferences.setShowHidden(value);
  }
}
