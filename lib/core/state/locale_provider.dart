import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/src/rust/api/settings.dart';

/// 界面语言。null 表示跟随系统。切换后立即生效，不需要重启，并保存到用户设置。
class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() => switch (ref.read(initialSettingsProvider).language) {
    'zh' => const Locale('zh'),
    'en' => const Locale('en'),
    _ => null, // 空值或无法识别的值都当作跟随系统
  };

  void set(Locale? locale) {
    if (ref.read(preferencesImportGateProvider).blocksWrites) return;
    state = locale;
    updateSettings(
      ref,
      (s) => Settings(
        language: locale?.languageCode,
        theme: s.theme,
        formatLocale: s.formatLocale,
      ),
    );
  }

  void applyImported(String? language) {
    state = switch (language) {
      'zh' => const Locale('zh'),
      'en' => const Locale('en'),
      _ => null,
    };
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);
