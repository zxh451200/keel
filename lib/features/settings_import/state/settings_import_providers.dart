import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/api/desktop_files.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/theme_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/src/rust/api/settings.dart'
    show Settings, RegionalSettings, ExternalConfigPreview;

class SettingsImportService {
  const SettingsImportService({
    required this.prepare,
    required this.commit,
    required this.settings,
    required this.navigation,
    required this.regional,
  });

  final Future<ExternalConfigPreview> Function(Uint8List) prepare;
  final Future<void> Function(String) commit;
  final Future<Settings> Function() settings;
  final Future<WorkspaceNavigationPreferences> Function() navigation;
  final Future<RegionalSettings> Function() regional;
}

final settingsImportServiceProvider = Provider<SettingsImportService>(
  (ref) => const SettingsImportService(
    prepare: prepareSettingsImport,
    commit: confirmSettingsImport,
    settings: loadSettingsFromRust,
    navigation: loadWorkspaceNavigationFromRust,
    regional: loadRegionalSettingsFromRust,
  ),
);

final settingsConfigFilePickerProvider =
    Provider<Future<String?> Function(String, String, String, String)>(
      (ref) => selectConfigurationFile,
    );

final settingsFilePrepareProvider =
    Provider<Future<ExternalConfigPreview> Function(String)>(
      (ref) => prepareSettingsFileImport,
    );

/// 排空旧快照后才导入；两份回读均成功后一次性应用，期间禁止新的偏好保存。
Future<void> commitSettingsImport(WidgetRef ref, String previewId) async {
  final gate = ref.read(preferencesImportGateProvider.notifier);
  if (!gate.begin()) return;
  final service = ref.read(settingsImportServiceProvider);
  final settingsSave = ref.read(settingsSaveProvider.notifier);
  final navigationSave = ref.read(workspaceNavigationSaveProvider.notifier);
  try {
    await Future.wait([settingsSave.drain(), navigationSave.drain()]);
    await service.commit(previewId);
    gate.saved();
    if (await _reload(ref, service)) gate.reloaded();
  } finally {
    gate.finish();
  }
}

/// 回读失败后仅重读，绝不重放已经消费的导入句柄。
Future<void> reloadImportedPreferences(WidgetRef ref) async {
  final gate = ref.read(preferencesImportGateProvider.notifier);
  if (!gate.begin(reload: true)) return;
  final service = ref.read(settingsImportServiceProvider);
  try {
    if (await _reload(ref, service)) gate.reloaded();
  } finally {
    gate.finish();
  }
}

Future<bool> _reload(WidgetRef ref, SettingsImportService service) async {
  final settings = await service.settings();
  final navigation = await service.navigation();
  final regional = await service.regional();
  // WidgetRef 可能已卸载：调用方页面有关闭守卫，但外部卸载仍不能访问失效 ref。
  if (!ref.context.mounted) return false;
  ref.read(settingsProvider.notifier).state = settings;
  ref.read(localeProvider.notifier).applyImported(settings.language);
  ref.read(themeModeProvider.notifier).applyImported(settings.theme);
  ref.read(formatLocaleProvider.notifier).applyImported(settings.formatLocale);
  ref.read(regionalSettingsProvider.notifier).applyImported(regional);
  ref
      .read(workspaceNavigationPreferencesProvider.notifier)
      .applyImported(navigation);
  ref.read(settingsSaveProvider.notifier).acceptImported();
  ref.read(workspaceNavigationSaveProvider.notifier).acceptImported();
  return true;
}
