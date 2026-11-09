import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:keel/api/desktop_print.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_print_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/audit.dart' as api;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/audit_page.dart';

void main() {
  const authorized = UserInfo(
    name: 'printer',
    role: 'admin',
    permissions: ['audit.export'],
  );
  late ProviderContainer container;
  late UserInfo latest;
  late ValueNotifier<bool> visible;
  late List<String> printed;
  Completer<UserInfo>? identityDelay;
  Completer<DesktopPrintResult>? printDelay;
  late int loads;
  late String targetSuffix;
  var containerDisposed = false;

  setUp(() async {
    await initializeDateFormatting();
    latest = authorized;
    visible = ValueNotifier(true);
    printed = [];
    loads = 0;
    targetSuffix = '\tcomplete\nsecond line';
    identityDelay = null;
    printDelay = null;
    containerDisposed = false;
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => authorized),
        userServiceProvider.overrideWithValue(
          UserService(
            current: () async {
              loads++;
              return identityDelay == null
                  ? latest
                  : await identityDelay!.future;
            },
            list: () async => [authorized],
            create: (_, _) async {},
            switchTo: (_) async => authorized,
          ),
        ),
        effectiveFormatLocaleProvider.overrideWithValue('en_GB'),
        auditSourceProvider.overrideWithValue(
          (_) async => api.AuditPage(
            items: List.generate(
              50,
              (i) => api.AuditItem(
                id: i + 1,
                at: i * 1000,
                actor: 'actor-$i',
                action: 'action-$i',
                target: 'target-$i$targetSuffix',
                result: 'result-$i',
              ),
            ),
            total: 150,
          ),
        ),
        auditPrinterProvider.overrideWithValue((title, content) async {
          printed.add(content);
          return printDelay == null
              ? DesktopPrintResult.printed
              : await printDelay!.future;
        }),
      ],
    );
  });

  tearDown(() {
    if (!containerDisposed) container.dispose();
    visible.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FluentLocalizations.delegate,
          ],
          home: ScaffoldPage(
            content: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: const AuditPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('audit-print-current-page')));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pump();
  }

  Future<void> pressPrint(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// displayInfoBar 的提示 250ms 后才显示、约 5 秒后自动关闭；用假时钟走完
  /// 全部 toast 定时器，避免测试结束遗留 pending timer。
  Future<void> flushToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Ctrl+P previews once and still requires explicit confirmation', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byType(TextBox).first);
    await pressPrint(tester);
    expect(find.byType(ContentDialog), findsOneWidget);
    expect(printed, isEmpty);
    expect(loads, 0);
    await pressPrint(tester);
    expect(find.byType(ContentDialog), findsOneWidget);
    expect(printed, isEmpty);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(printed, hasLength(1));
    expect(container.read(auditPrintBusyProvider), isFalse);
    await flushToasts(tester);
  });

  testWidgets('timezone changes invalidate an open print preview', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    container.read(regionalSettingsProvider.notifier).setTimeZone('UTC');
    await tester.pump();
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(printed, isEmpty);
    expect(loads, 0);
    expect(container.read(auditPrintBusyProvider), isFalse);
  });

  testWidgets('Ctrl+P rejects a busy or hidden audit page', (tester) async {
    await mount(tester);
    await tester.tap(find.byType(TextBox).first);
    final lock = container.read(auditPrintBusyProvider.notifier);
    final owner = lock.acquire()!;
    await tester.pump();
    await pressPrint(tester);
    expect(find.byType(ContentDialog), findsNothing);
    lock.release(owner);
    visible.value = false;
    await tester.pump();
    await pressPrint(tester);
    expect(find.byType(ContentDialog), findsNothing);
    expect(printed, isEmpty);
    expect(loads, 0);
  });

  testWidgets('previews every row and all five complete columns', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    expect(container.read(auditPrintBusyProvider), isTrue);
    final text = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('audit-print-preview-text')),
        )
        .data!;
    for (var i = 0; i < 50; i++) {
      expect(text, contains('actor-$i'));
      expect(text, contains('action-$i'));
      expect(text, contains('target-$i    complete\nsecond line'));
      expect(text, contains('result-$i'));
    }
    expect(printed, isEmpty);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(printed, [text]);
    expect(container.read(auditPrintBusyProvider), isFalse);
    await flushToasts(tester);
  });

  testWidgets(
    'cancel never calls loader or printer and releases after dismissal',
    (tester) async {
      await mount(tester);
      await preview(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ContentDialog),
          matching: find.widgetWithText(Button, 'Cancel'),
        ),
      );
      // The preview reverse transition is still protected.
      expect(container.read(auditPrintBusyProvider), isTrue);
      await tester.pumpAndSettle();
      expect(loads, 0);
      expect(printed, isEmpty);
      expect(container.read(auditPrintBusyProvider), isFalse);
      await flushToasts(tester);
    },
  );

  for (final changed in [
    const UserInfo(name: 'other', role: 'admin', permissions: ['audit.export']),
    const UserInfo(
      name: 'printer',
      role: 'viewer',
      permissions: ['audit.export'],
    ),
    const UserInfo(name: 'printer', role: 'admin', permissions: []),
  ]) {
    testWidgets(
      'fresh loader rejects changed identity ${changed.name}/${changed.role}/${changed.permissions}',
      (tester) async {
        await mount(tester);
        await preview(tester);
        latest = changed; // Cached provider intentionally remains authorized.
        await confirm(tester);
        await tester.pumpAndSettle();
        expect(loads, 1);
        expect(printed, isEmpty);
        expect(container.read(auditPrintBusyProvider), isFalse);
        await flushToasts(tester);
      },
    );
  }

  testWidgets('loader and native call share the same single-flight lock', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    identityDelay = Completer<UserInfo>();
    printDelay = Completer<DesktopPrintResult>();
    await confirm(tester);
    expect(loads, 1);
    expect(container.read(auditPrintBusyProvider), isTrue);
    final button = tester.widget<FilledButton>(
      find.descendant(
        of: find.byType(ContentDialog),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(container.read(auditPrintBusyProvider.notifier).acquire(), isNull);
    identityDelay!.complete(authorized);
    await tester.pump();
    expect(printed, hasLength(1));
    expect(container.read(auditPrintBusyProvider), isTrue);
    printDelay!.complete(DesktopPrintResult.cancelled);
    await tester.pumpAndSettle();
    expect(container.read(auditPrintBusyProvider), isFalse);
    // 提示先以淡出状态挂载，250ms 后才显示文本。
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Printing was cancelled.'), findsOneWidget);
    await flushToasts(tester);
  });

  for (final change in ['query', 'reload', 'identity', 'visibility']) {
    testWidgets('rejects old preview after $change generation changes', (
      tester,
    ) async {
      await mount(tester);
      await preview(tester);
      identityDelay = Completer<UserInfo>();
      await confirm(tester);
      switch (change) {
        case 'query':
          container.read(auditFilterProvider.notifier).state =
              const AuditFilter(keyword: 'changed');
        case 'reload':
          container.invalidate(auditPageProvider);
        case 'identity':
          container.invalidate(currentUserProvider);
        case 'visibility':
          visible.value = false;
      }
      await tester.pump();
      if (change == 'visibility') {
        visible.value = true;
        await tester.pump();
      }
      identityDelay!.complete(authorized);
      await tester.pumpAndSettle();
      expect(printed, isEmpty);
      expect(container.read(auditPrintBusyProvider), isFalse);
    });
  }

  testWidgets(
    'disposal retains native busy and suppresses completion feedback',
    (tester) async {
      await mount(tester);
      await preview(tester);
      printDelay = Completer<DesktopPrintResult>();
      await confirm(tester);
      expect(printed, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(container.read(auditPrintBusyProvider), isTrue);
      printDelay!.complete(DesktopPrintResult.printed);
      await tester.pumpAndSettle();
      expect(container.read(auditPrintBusyProvider), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loader failure releases busy without invoking native print', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    identityDelay = Completer<UserInfo>();
    await confirm(tester);
    identityDelay!.completeError(StateError('private loader detail'));
    await tester.pumpAndSettle();
    expect(printed, isEmpty);
    expect(container.read(auditPrintBusyProvider), isFalse);
    expect(find.textContaining('private loader detail'), findsNothing);
    await flushToasts(tester);
  });

  for (final suffix in [
    List.filled(5, '\nline').join(),
    List.filled(desktopPrintMaxBytes ~/ 40, 'é').join(),
  ]) {
    testWidgets(
      'oversized complete report is rejected before preview ${suffix.length}',
      (tester) async {
        targetSuffix = suffix;
        await mount(tester);
        await preview(tester);
        expect(
          find.byKey(const ValueKey('audit-print-preview-text')),
          findsNothing,
        );
        expect(loads, 0);
        expect(printed, isEmpty);
        expect(container.read(auditPrintBusyProvider), isFalse);
        await flushToasts(tester);
      },
    );
  }

  testWidgets('query change and restore permanently invalidates old preview', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    final original = container.read(auditFilterProvider);
    container.read(auditFilterProvider.notifier).state = const AuditFilter(
      keyword: 'temporary',
    );
    container.read(auditFilterProvider.notifier).state = original;
    await tester.pumpAndSettle();
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(printed, isEmpty);
    expect(container.read(auditPrintBusyProvider), isFalse);
  });

  testWidgets('covered preview completes without leaving its lock held', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    printDelay = Completer<DesktopPrintResult>();
    await confirm(tester);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    final overlay = showDialog<void>(
      context: navigator.context,
      builder: (_) => const ContentDialog(title: Text('Overlay')),
    );
    await tester.pumpAndSettle();
    printDelay!.complete(DesktopPrintResult.printed);
    await tester.pumpAndSettle();
    expect(find.text('Overlay'), findsOneWidget);
    expect(container.read(auditPrintBusyProvider), isFalse);
    navigator.pop();
    await overlay;
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('audit-print-preview-text')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('container disposal during native print has safe cleanup', (
    tester,
  ) async {
    await mount(tester);
    await preview(tester);
    printDelay = Completer<DesktopPrintResult>();
    await confirm(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    containerDisposed = true;
    printDelay!.complete(DesktopPrintResult.printed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
