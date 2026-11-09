import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/audit.dart' as api;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/audit_page.dart';

void main() {
  const user = UserInfo(name: 'reader', role: 'viewer', permissions: []);
  final items = [
    const api.AuditItem(
      id: 1,
      at: 0,
      actor: 'actor-0',
      action: ' =SUM(A1)',
      target: 'a\tb\n"c"',
      result: '@result',
    ),
    const api.AuditItem(
      id: 2,
      at: 1000,
      actor: 'actor-1',
      action: 'read',
      target: 'target-1',
      result: 'ok',
    ),
    const api.AuditItem(
      id: 3,
      at: 2000,
      actor: 'actor-2',
      action: 'read',
      target: 'target-2',
      result: 'ok',
    ),
  ];
  late ProviderContainer container;
  late List<api.AuditItem> pageItems;
  late ValueNotifier<bool> visible;
  late List<String> copies;
  Completer<void>? clipboardDelay;
  late GlobalKey<NavigatorState> navigator;

  setUp(() async {
    await initializeDateFormatting();
    pageItems = items;
    copies = [];
    clipboardDelay = null;
    visible = ValueNotifier(true);
    navigator = GlobalKey<NavigatorState>();
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => user),
        effectiveFormatLocaleProvider.overrideWithValue('en_GB'),
        auditSourceProvider.overrideWithValue(
          (_) async => api.AuditPage(items: pageItems, total: 12345),
        ),
        // 组件测试不加载 Rust 库：列布局存储用内存实现。
        gridColumnLayoutStoreProvider.overrideWithValue(
          InMemoryGridColumnLayoutStore(),
        ),
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copies.add((call.arguments as Map)['text'] as String);
            await clipboardDelay?.future;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    container.dispose();
    visible.dispose();
  });

  Future<void> pumpPage(WidgetTester tester, {double width = 1100}) async {
    await tester.binding.setSurfaceSize(Size(width, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          navigatorKey: navigator,
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FluentLocalizations.delegate,
          ],
          home: ScaffoldPage(
            content: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, value, child) =>
                  TickerMode(enabled: value, child: child!),
              child: const AuditPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> copyKey(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Button copyButton(WidgetTester tester) =>
      tester.widget<Button>(find.widgetWithText(Button, 'Copy selected row'));

  testWidgets('copies display columns as escaped formula-safe TSV', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('actor-0'));
    await tester.pump();
    await copyKey(tester);
    final time = DateFormat.yMd('en_GB')
        .add_Hms()
        .format(DateTime.fromMillisecondsSinceEpoch(0));
    expect(
      copies.single,
      '$time\tactor-0\t\' =SUM(A1)\t"a\tb\n""c"""\t\'@result',
    );
    expect(find.textContaining('12,345'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(copyButton(tester).onPressed, isNull);
    // 让复制提示 toast 的定时器走完，避免测试结束时遗留 pending timer。
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('supports current-page Ctrl and Shift selection and navigation', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('actor-0'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('actor-2'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await copyKey(tester);
    expect(copies.single.split('\r\n'), hasLength(2));
    expect(copies.single, isNot(contains('actor-1')));
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await copyKey(tester);
    expect(copies.last.split('\r\n'), hasLength(3));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await copyKey(tester);
    expect(copies.last, contains('actor-1'));
    expect(copies.last.split('\r\n'), hasLength(1));
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('query, sort, page, reload and identity reset selection', (
    tester,
  ) async {
    await pumpPage(tester);
    for (final change in <void Function()>[
      () => container.read(auditFilterProvider.notifier).state =
          const AuditFilter(keyword: 'read'),
      () => container.read(auditFilterProvider.notifier).state =
          const AuditFilter(
            sort: [api.AuditSort(field: 'actor', descending: false)],
          ),
      () => container.read(auditFilterProvider.notifier).state =
          const AuditFilter(page: 2),
      () => container.invalidate(auditPageProvider),
      () => container.invalidate(currentUserProvider),
    ]) {
      await tester.tap(find.text('actor-0'));
      await tester.pump();
      expect(copyButton(tester).onPressed, isNotNull);
      change();
      await tester.pumpAndSettle();
      expect(copyButton(tester).onPressed, isNull);
    }
  });

  testWidgets('hidden page and modal suppress keys and delayed copy feedback', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('actor-0'));
    clipboardDelay = Completer<void>();
    await copyKey(tester);
    visible.value = false;
    await tester.pump();
    await copyKey(tester);
    expect(copies, hasLength(1));
    clipboardDelay!.complete();
    await tester.pump();
    expect(find.text('Selected row copied.'), findsNothing);
    visible.value = true;
    await tester.pump();
    clipboardDelay = Completer<void>();
    await tester.tap(find.widgetWithText(Button, 'Copy selected row'));
    await tester.pump();
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(AuditPage)),
        builder: (_) => const ContentDialog(title: Text('modal fixture')),
      ),
    );
    await tester.pumpAndSettle();
    await copyKey(tester);
    expect(copies, hasLength(2));
    clipboardDelay!.complete();
    await tester.pump();
    expect(find.text('Selected row copied.'), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('horizontal scroll moves header and cells together', (
    tester,
  ) async {
    await pumpPage(tester, width: 780);
    final scroll = find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );
    final before = tester.getTopLeft(find.text('actor-0')).dx;
    final headerBefore = tester.getTopLeft(find.text('Actor')).dx;
    await tester.drag(scroll, const Offset(-100, 0));
    await tester.pumpAndSettle();
    final delta = tester.getTopLeft(find.text('actor-0')).dx - before;
    final headerDelta = tester.getTopLeft(find.text('Actor')).dx - headerBefore;
    expect(delta, lessThan(0));
    expect(headerDelta, closeTo(delta, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search retains its own copy and navigation keys', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('actor-0'));
    await tester.enterText(find.byType(TextBox), 'search fixture');
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    editable.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await copyKey(tester);
    expect(copies.single, 'search');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(editable.controller.selection.extentOffset, 'search fixture'.length);
  });

  testWidgets('selecting rows preserves horizontal scroll position', (
    tester,
  ) async {
    await pumpPage(tester, width: 780);
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          ),
        )
        .controller!;
    await tester.tap(find.text('actor-0'));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    scroll.jumpTo(80);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scroll.offset, 80);
  });

  testWidgets(
    'End and Home reveal offscreen rows without horizontal movement',
    (tester) async {
      pageItems = List.generate(
        50,
        (i) => api.AuditItem(
          id: i + 1,
          at: i * 1000,
          actor: 'many-actor-$i',
          action: 'read',
          target: 'target',
          result: 'ok',
        ),
      );
      await pumpPage(tester, width: 780);
      final horizontalFinder = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      final horizontal = tester
          .widget<SingleChildScrollView>(horizontalFinder)
          .controller!;
      // start/body/end 三个 pane 各有纵向视图；body 的在横向视图内部。
      final vertical = tester
          .widget<SingleChildScrollView>(
            find.descendant(
              of: horizontalFinder,
              matching: find.byWidgetPredicate(
                (w) =>
                    w is SingleChildScrollView &&
                    w.scrollDirection == Axis.vertical,
              ),
            ),
          )
          .controller!;
      await tester.tap(find.text('many-actor-0'));
      horizontal.jumpTo(80);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(vertical.offset, greaterThan(0));
      expect(horizontal.offset, 80);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(vertical.offset, 0);
      expect(horizontal.offset, 80);
    },
  );

  testWidgets('opens user-scoped read-only column settings', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('audit-column-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Column settings'), findsOneWidget);
    expect(find.text('Visible'), findsNWidgets(5));
    expect(find.textContaining('read-only audit table'), findsOneWidget);
  });

  testWidgets('disposal discards pending clipboard completion', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('actor-0'));
    clipboardDelay = Completer<void>();
    await copyKey(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    clipboardDelay!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('200% text scale keeps the filter bar and table usable', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpPage(tester, width: 780);
    expect(tester.takeException(), isNull);
    expect(find.byType(TextBox), findsWidgets);
  });
}
