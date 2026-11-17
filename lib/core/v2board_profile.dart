import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';

/// Dawn 订阅配置（Profile）的读写。
///
/// 放在 core 而不是 features/v2board：UI 层禁止直接摸 `globalState.container`
/// （test/lint/ui_layer_singleton_test.dart），而登录态/心跳这些非 widget 代码
/// 又需要在启动、刷新时改写订阅列表。
const dawnProfileLabel = 'Dawn';

bool hasDawnProfile() {
  final profiles = globalState.container.read(profilesProvider);
  return profiles.any((profile) => profile.label == dawnProfileLabel);
}

/// 拉取链接并生成一条 Dawn 订阅配置；[replace] 为真时先删掉旧的 Dawn 配置，
/// 保证「刷新订阅」不会越点越多条。
Future<void> addDawnProfileFromLink(String url, {bool replace = false}) async {
  final notifier = globalState.container.read(profilesActionProvider.notifier);
  if (replace) {
    final ids = [
      for (final profile in globalState.container.read(profilesProvider))
        if (profile.label == dawnProfileLabel) profile.id,
    ];
    for (final id in ids) {
      try {
        await notifier.deleteProfile(id);
      } catch (e) {
        commonPrint.log('[V2Board] 清理旧订阅配置失败: $e');
      }
    }
  }
  await notifier.addProfileFromLink(url, label: dawnProfileLabel);
}
