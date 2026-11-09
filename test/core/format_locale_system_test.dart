import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/src/rust/api/settings.dart' show Settings;

/// 真实平台的 `PlatformDispatcher.locale` 恒等于 `locales.first`；
/// 测试用的 TestPlatformDispatcher 里 `locale` 与 `localesTestValue` 是两份
/// 独立数据（`locale` 只受 `localeTestValue` 影响），所以两个值一起改才等价于
/// 一次真实的系统区域变化。
void setSystemLocale(WidgetTester tester, Locale locale) {
  tester.platformDispatcher.localeTestValue = locale;
  tester.platformDispatcher.localesTestValue = [locale];
}

void main() {
  group('resolveSystemFormatLocale', () {
    test('maps Chinese systems to zh_CN', () {
      for (final value in ['zh', 'zh_CN', 'zh_TW', 'zh_HK', 'zh-Hans-CN']) {
        expect(resolveSystemFormatLocale(value), 'zh_CN', reason: value);
      }
    });

    test('keeps British English in en_GB and other English in en_US', () {
      for (final value in ['en_GB', 'en-GB']) {
        expect(resolveSystemFormatLocale(value), 'en_GB', reason: value);
      }
      for (final value in ['en', 'en_US', 'en_AU', 'en_CA', 'en_IN']) {
        expect(resolveSystemFormatLocale(value), 'en_US', reason: value);
      }
    });

    test('falls back to en_US for unsupported systems and missing locale', () {
      for (final value in ['de_DE', 'fr_FR', 'ja_JP', 'ru_RU', '', 'null']) {
        expect(resolveSystemFormatLocale(value), 'en_US', reason: value);
      }
    });
  });

  group('system format locale provider', () {
    testWidgets('follows a running system locale change when unset', (
      tester,
    ) async {
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 第一次读取会注册平台观察者，后续变化走 didChangeLocales 刷新路径。
      container.read(effectiveFormatLocaleProvider);
      expect(container.read(formatLocaleProvider), isNull);

      setSystemLocale(tester, const Locale('zh', 'CN'));
      expect(container.read(systemFormatLocaleProvider), 'zh_CN');
      expect(container.read(effectiveFormatLocaleProvider), 'zh_CN');

      setSystemLocale(tester, const Locale('en', 'GB'));
      expect(container.read(effectiveFormatLocaleProvider), 'en_GB');

      setSystemLocale(tester, const Locale('en', 'US'));
      expect(container.read(effectiveFormatLocaleProvider), 'en_US');

      // 不支持的系统区域回退 en_US，并继续响应后续变化。
      setSystemLocale(tester, const Locale('ja', 'JP'));
      expect(container.read(effectiveFormatLocaleProvider), 'en_US');
      setSystemLocale(tester, const Locale('zh', 'TW'));
      expect(container.read(effectiveFormatLocaleProvider), 'zh_CN');
    });

    testWidgets('an explicit region ignores system changes and never writes', (
      tester,
    ) async {
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final writes = <Settings>[];
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const Settings(language: null, theme: null, formatLocale: 'en_GB'),
          ),
          settingsSinkProvider.overrideWithValue((settings) async {
            writes.add(settings);
          }),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(formatLocaleProvider), 'en_GB');
      expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
      container.read(systemFormatLocaleProvider);

      setSystemLocale(tester, const Locale('zh', 'CN'));
      // 系统区域确实变了，但显式区域不受影响，也不回写配置。
      expect(container.read(systemFormatLocaleProvider), 'zh_CN');
      expect(container.read(formatLocaleProvider), 'en_GB');
      expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
      expect(writes, isEmpty);

      setSystemLocale(tester, const Locale('ja', 'JP'));
      expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
      expect(writes, isEmpty);
    });

    testWidgets('following the system does not persist the resolved value', (
      tester,
    ) async {
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final writes = <Settings>[];
      final container = ProviderContainer(
        overrides: [
          settingsSinkProvider.overrideWithValue((settings) async {
            writes.add(settings);
          }),
        ],
      );
      addTearDown(container.dispose);

      container.read(effectiveFormatLocaleProvider);
      setSystemLocale(tester, const Locale('zh', 'CN'));
      setSystemLocale(tester, const Locale('en', 'GB'));
      expect(container.read(effectiveFormatLocaleProvider), 'en_GB');
      // 跟随系统仍保持 null，变化只影响显示，不写配置、不产生审计事件。
      expect(container.read(formatLocaleProvider), isNull);
      expect(writes, isEmpty);
    });

    testWidgets('the observer detaches with the container', (tester) async {
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final container = ProviderContainer();
      expect(container.read(effectiveFormatLocaleProvider), isNotNull);
      container.dispose();
      // 容器销毁后平台事件仍会广播；已释放的观察者不得抛错。
      setSystemLocale(tester, const Locale('zh', 'CN'));
      expect(tester.takeException(), isNull);
    });
  });
}
