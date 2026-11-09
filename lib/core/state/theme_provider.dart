import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/src/rust/api/settings.dart';

/// 界面主题模式；不依赖 Material 的 ThemeMode。
enum KeelThemeMode { system, light, dark }

/// 主题模式，默认跟随系统。切换后立即生效，并保存到用户设置。
class ThemeModeNotifier extends Notifier<KeelThemeMode> {
  @override
  KeelThemeMode build() => switch (ref.read(initialSettingsProvider).theme) {
    'light' => KeelThemeMode.light,
    'dark' => KeelThemeMode.dark,
    _ => KeelThemeMode.system,
  };

  void set(KeelThemeMode mode) {
    if (ref.read(preferencesImportGateProvider).blocksWrites) return;
    state = mode;
    updateSettings(
      ref,
      (s) => Settings(
        language: s.language,
        formatLocale: s.formatLocale,
        theme: switch (mode) {
          KeelThemeMode.light => 'light',
          KeelThemeMode.dark => 'dark',
          KeelThemeMode.system => null,
        },
      ),
    );
  }

  void applyImported(String? theme) {
    state = switch (theme) {
      'light' => KeelThemeMode.light,
      'dark' => KeelThemeMode.dark,
      _ => KeelThemeMode.system,
    };
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, KeelThemeMode>(
  ThemeModeNotifier.new,
);
