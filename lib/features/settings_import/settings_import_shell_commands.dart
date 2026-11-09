import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/ui/ui_page.dart';

/// 不依赖输入文本与预览句柄的动作：由页面注册，外壳命令只调用已注册实例。
/// 预览/确认仍留在页内，因为它们绑定当前文本框内容与单次预览句柄。
class SettingsImportPageActions {
  const SettingsImportPageActions({
    required this.openFile,
    required this.cancel,
    required this.reload,
  });

  final Future<void> Function() openFile;
  final VoidCallback cancel;
  final Future<void> Function() reload;
}

class SettingsImportActionsRegistry
    extends Notifier<SettingsImportPageActions?> {
  @override
  SettingsImportPageActions? build() => null;

  void register(SettingsImportPageActions actions) => state = actions;

  void unregister(SettingsImportPageActions actions) {
    if (identical(state, actions)) state = null;
  }
}

final settingsImportActionsProvider =
    NotifierProvider<SettingsImportActionsRegistry, SettingsImportPageActions?>(
      SettingsImportActionsRegistry.new,
    );

final settingsImportOpenFileEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(settingsImportActionsProvider) != null &&
      hasPermission(ref.watch(currentUserProvider).value, 'settings.import') &&
      ref.watch(settingsWritableProvider) &&
      ref.watch(workspaceNavigationWritableProvider) &&
      !ref.watch(preferencesImportGateProvider).blocksWrites,
);

final settingsImportCancelEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(settingsImportActionsProvider) != null &&
      !ref.watch(preferencesImportGateProvider).blocksWrites,
);

final settingsImportReloadEnabledProvider = Provider<bool>((ref) {
  final gate = ref.watch(preferencesImportGateProvider);
  return ref.watch(settingsImportActionsProvider) != null &&
      gate.reloadRequired &&
      !gate.busy;
});

/// 导入设置页的统一命令：文件导入、取消与失败后的重新载入。
List<UiCommand> settingsImportShellCommands() => [
  UiCommand(
    id: 'settingsImport.openFile',
    label: (t) => t.settingsImportChooseFile,
    icon: FluentIcons.open_file,
    isEnabledProvider: settingsImportOpenFileEnabledProvider,
    onInvoke: (context, ref) async {
      final actions = ref.read(settingsImportActionsProvider);
      if (actions == null) return;
      await actions.openFile();
    },
  ),
  UiCommand(
    id: 'settingsImport.cancel',
    label: (t) => t.actionCancel,
    icon: FluentIcons.cancel,
    isEnabledProvider: settingsImportCancelEnabledProvider,
    onInvoke: (context, ref) async {
      final actions = ref.read(settingsImportActionsProvider);
      if (actions == null) return;
      actions.cancel();
    },
  ),
  UiCommand(
    id: 'settingsImport.reload',
    label: (t) => t.actionRetry,
    icon: FluentIcons.sync,
    isEnabledProvider: settingsImportReloadEnabledProvider,
    onInvoke: (context, ref) async {
      final actions = ref.read(settingsImportActionsProvider);
      if (actions == null) return;
      await actions.reload();
    },
  ),
];
