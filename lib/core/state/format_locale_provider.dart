import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/src/rust/api/settings.dart';

/// 当前支持的显示区域；与界面语言、时区和币种分别管理。
const supportedFormatLocales = ['en_US', 'en_GB', 'zh_CN'];

/// 不支持的系统区域使用 en_US；中文系统使用 zh_CN，其余英文使用 en_US。
String resolveSystemFormatLocale(String locale) {
  final normalized = locale.replaceAll('-', '_');
  if (supportedFormatLocales.contains(normalized)) return normalized;
  final parts = normalized.split('_');
  if (parts.first == 'zh') return 'zh_CN';
  if (parts.first == 'en' && parts.skip(1).contains('GB')) return 'en_GB';
  return 'en_US';
}

final systemFormatLocaleProvider = Provider<String>((ref) {
  final binding = WidgetsBinding.instance;
  final observer = _FormatLocaleObserver(ref.invalidateSelf);
  binding.addObserver(observer);
  ref.onDispose(() => binding.removeObserver(observer));
  return binding.platformDispatcher.locale.toString();
});

class _FormatLocaleObserver extends WidgetsBindingObserver {
  _FormatLocaleObserver(this.onChanged);
  final void Function() onChanged;

  @override
  void didChangeLocales(List<Locale>? locales) => onChanged();
}

class FormatLocaleNotifier extends Notifier<String?> {
  @override
  String? build() => ref.read(initialSettingsProvider).formatLocale;

  void set(String? locale) {
    if (ref.read(preferencesImportGateProvider).blocksWrites ||
        (locale != null && !supportedFormatLocales.contains(locale))) {
      return;
    }
    state = locale;
    updateSettings(
      ref,
      (s) =>
          Settings(language: s.language, theme: s.theme, formatLocale: locale),
    );
  }

  /// 导入回读只更新内存，不追加保存请求。
  void applyImported(String? locale) => state = locale;
}

final formatLocaleProvider = NotifierProvider<FormatLocaleNotifier, String?>(
  FormatLocaleNotifier.new,
);

final Future<void> _dateFormattingReady = initializeDateFormatting();

final effectiveFormatLocaleProvider = Provider<String>((ref) {
  // intl 的本地数据入口同步注册内置符号和模式，返回的 Future 不执行网络 I/O。
  // 即使界面语言只加载了 en，独立的 en_GB / zh_CN 日期格式也能使用。
  unawaited(_dateFormattingReady);
  final selected = ref.watch(formatLocaleProvider);
  if (selected != null && supportedFormatLocales.contains(selected)) {
    return selected;
  }
  return resolveSystemFormatLocale(ref.watch(systemFormatLocaleProvider));
});
