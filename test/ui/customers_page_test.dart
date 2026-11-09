import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/customers/state/customers_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/customers.dart';
import 'package:keel/src/rust/api/error.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/customers_page.dart';

const _admin = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: ['audit.read', 'customers.manage'],
);
const _viewer = UserInfo(
  name: 'vic',
  role: 'viewer',
  permissions: ['audit.read'],
);

CustomerItem _item(int id) => CustomerItem(
  id: id,
  code: 'C-${id.toString().padLeft(3, '0')}',
  name: 'Acme $id',
  kind: id.isEven ? 'supplier' : 'customer',
  phone: '',
  email: '',
  active: true,
  note: '',
  updatedAt: 1762500000000 + id,
  updatedBy: 'local',
);

void main() {
  late List<CustomerQuery> queries;
  late List<SaveCustomerRequest> creates;
  late List<(int, SaveCustomerRequest)> updates;
  late List<List<int>> deletes;
  late List<(List<int>, bool)> activeCalls;
  late List<String?> clipboard;
  late List<CustomerItem> rows;
  Object? writeError;

  List<CustomerItem> all() => [for (var i = 1; i <= 120; i++) _item(i)];

  Future<void> drainToasts(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  Future<void> pump(
    WidgetTester tester, {
    UserInfo user = _admin,
    Size size = const Size(1280, 800),
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) async => user),
          regionalInstantFormatterProvider.overrideWithValue(
            (epoch) => 'at $epoch',
          ),
          customerSourceProvider.overrideWithValue((query) async {
            queries.add(query);
            final keyword = query.keyword.toLowerCase();
            final matched = rows.where(
              (item) =>
                  keyword.isEmpty ||
                  item.code.toLowerCase().contains(keyword) ||
                  item.name.toLowerCase().contains(keyword),
            );
            final start = (query.page - 1) * query.pageSize;
            final items = matched.skip(start).take(query.pageSize).toList();
            return CustomerPage(items: items, total: matched.length);
          }),
          customerWriterProvider.overrideWithValue(
            CustomerWriter(
              create: (request) async {
                if (writeError != null) throw writeError!;
                creates.add(request);
                return 500;
              },
              update: (id, request) async {
                if (writeError != null) throw writeError!;
                updates.add((id, request));
              },
              deleteMany: (ids) async {
                if (writeError != null) throw writeError!;
                deletes.add(ids);
                // 模拟数据库真的删掉这些行，后续刷新才能看到收缩。
                rows.removeWhere((item) => ids.contains(item.id));
                return ids.length;
              },
              setActiveMany: (ids, active) async {
                if (writeError != null) throw writeError!;
                activeCalls.add((ids, active));
                return ids.length;
              },
            ),
          ),
        ],
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Directionality(
            textDirection: textDirection,
            child: const ScaffoldPage(content: CustomersPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    queries = [];
    creates = [];
    updates = [];
    deletes = [];
    activeCalls = [];
    clipboard = [];
    rows = all();
    writeError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('lists one page with total and paging', (tester) async {
    await pump(tester);
    expect(find.text('C-001'), findsOneWidget);
    expect(find.text('Acme 1'), findsOneWidget);
    expect(find.text('Total: 120'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('customers-page-info')))
          .data,
      'Page 1 / 3',
    );

    await tester.tap(find.byKey(const ValueKey('customers-next')));
    await tester.pumpAndSettle();
    expect(queries.last.page, 2);
    expect(find.text('C-051'), findsOneWidget);
    expect(find.text('C-001'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('customers-page-info')))
          .data,
      'Page 2 / 3',
    );
  });

  testWidgets('search resets to the first page and filters in Rust', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('customers-next')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('customers-search')),
      'Acme 11',
    );
    await tester.tap(find.byKey(const ValueKey('customers-apply')));
    await tester.pumpAndSettle();
    expect(queries.last.keyword, 'Acme 11');
    expect(queries.last.page, 1);
    expect(find.text('C-011'), findsOneWidget);
    expect(find.text('Total: 11'), findsOneWidget);
  });

  testWidgets('viewer sees the read-only notice and cannot mutate', (
    tester,
  ) async {
    await pump(tester, user: _viewer);
    expect(
      find.text('Your role can view this list but not change it.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('customers-new')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    for (final key in const [
      'customers-enable',
      'customers-disable',
      'customers-delete',
    ]) {
      expect(
        tester.widget<Button>(find.byKey(ValueKey(key))).onPressed,
        isNull,
        reason: key,
      );
    }
    // 复制只读数据仍允许。
    expect(
      tester
          .widget<Button>(find.byKey(const ValueKey('customers-copy')))
          .onPressed,
      isNotNull,
    );
    // Delete/Enter 快捷键也不能绕过权限。
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
  });

  testWidgets('creating an entry validates locally and saves', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('customers-new')));
    await tester.pumpAndSettle();

    // 空编号在本地被拒绝，不触发写入。
    await tester.tap(find.byKey(const ValueKey('customers-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('customers-error')), findsOneWidget);
    expect(creates, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('customers-code')),
      ' acme-77 ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('customers-name')),
      'Acme 新客户',
    );
    await tester.enterText(
      find.byKey(const ValueKey('customers-phone')),
      '+86 21 5555 0101',
    );
    await tester.enterText(
      find.byKey(const ValueKey('customers-email')),
      'sales@acme.example',
    );
    await tester.tap(find.byKey(const ValueKey('customers-save')));
    await tester.pumpAndSettle();

    expect(creates, hasLength(1));
    expect(creates.single.code, 'acme-77');
    expect(creates.single.name, 'Acme 新客户');
    expect(creates.single.kind, 'customer');
    expect(creates.single.active, isTrue);
    expect(find.byType(ContentDialog), findsNothing);
    // 保存成功会显示 toast；让它自己的计时器走完，避免测试结束时报 pending timer。
    await drainToasts(tester);
  });

  testWidgets(
    'server duplicate keeps the dialog open with a translated error',
    (tester) async {
      writeError = const ApiError(
        code: 'KEEL-DUPLICATE',
        message: '记录已存在',
        correlationId: '',
      );
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('customers-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('customers-code')),
        'C-001',
      );
      await tester.enterText(
        find.byKey(const ValueKey('customers-name')),
        '重复',
      );
      await tester.tap(find.byKey(const ValueKey('customers-save')));
      await tester.pumpAndSettle();

      expect(find.byType(ContentDialog), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('customers-error'))).data,
        'That item already exists.',
      );
      expect(creates, isEmpty);
    },
  );

  testWidgets('editing an entry sends its id and keeps the original code', (
    tester,
  ) async {
    await pump(tester);
    final edit = find.byKey(const ValueKey('customers-edit'));
    // 未选中时编辑按钮不可用；选中后可用（键盘/鼠标都能到达，不依赖双击）。
    expect(tester.widget<Button>(edit).onPressed, isNull);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    expect(tester.widget<Button>(edit).onPressed, isNotNull);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('customers-name')),
      'Acme 改名',
    );
    await tester.tap(find.byKey(const ValueKey('customers-save')));
    await tester.pumpAndSettle();
    expect(updates, hasLength(1));
    expect(updates.single.$1, 1);
    expect(updates.single.$2.code, 'C-001');
    expect(updates.single.$2.name, 'Acme 改名');
    await drainToasts(tester);
  });

  testWidgets(
    'Ctrl-click and Shift-click build a selection that copies as TSV',
    (tester) async {
      await pump(tester);
      await tester.tap(find.text('Acme 1'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('Acme 2'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.tap(find.byKey(const ValueKey('customers-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, hasLength(1));
      expect(
        clipboard.single,
        'C-001\tAcme 1\tCustomer\t\tActive\r\n'
        'C-002\tAcme 2\tSupplier\t\tActive',
      );
      await drainToasts(tester);

      // Shift 从锚点扩展到第 4 行。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Acme 4'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const ValueKey('customers-copy')));
      await tester.pumpAndSettle();
      // Shift 从锚点（第 2 行）扩展到第 4 行：2..4 共 3 行。
      final shifted = clipboard.last!.split('\r\n');
      expect(shifted, hasLength(3));
      expect(shifted.first, startsWith('C-002'));
      expect(shifted.last, startsWith('C-004'));
      await drainToasts(tester);
    },
  );

  testWidgets('keyboard navigation moves the cursor and Esc clears it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('customers-copy')));
    await tester.pumpAndSettle();
    expect(clipboard.last, startsWith('C-050\tAcme 50'));
    await drainToasts(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Button>(find.byKey(const ValueKey('customers-copy')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('delete asks for confirmation and sends the selected ids', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Acme 2'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    await tester.tap(find.byKey(const ValueKey('customers-delete')));
    await tester.pumpAndSettle();
    // 英文复数：两条用 entries。
    expect(find.textContaining('Delete 2 entries?'), findsOneWidget);
    // 取消不写入（确认框的取消按钮没有独立 key）。
    await tester.tap(find.widgetWithText(Button, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(deletes, isEmpty);

    await tester.tap(find.byKey(const ValueKey('customers-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
    await tester.pumpAndSettle();
    expect(deletes, [
      [1, 2],
    ]);
    // 操作后清空选择。
    expect(
      tester
          .widget<Button>(find.byKey(const ValueKey('customers-delete')))
          .onPressed,
      isNull,
    );
    expect(queries.length, greaterThan(1));
    await drainToasts(tester);
  });

  testWidgets('batch disable sends every selected id', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Acme 3'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    await tester.tap(find.byKey(const ValueKey('customers-disable')));
    await tester.pumpAndSettle();
    expect(activeCalls, hasLength(1));
    expect(activeCalls.single.$1, [1, 3]);
    expect(activeCalls.single.$2, isFalse);
    await drainToasts(tester);
  });

  testWidgets('deleting the last page falls back to the previous page', (
    tester,
  ) async {
    // 51 条 = 2 页，第 2 页只有 1 条；删掉它之后应回到第 1 页而不是停在空页。
    rows = [for (var i = 1; i <= 51; i++) _item(i)];
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('customers-next')));
    await tester.pumpAndSettle();
    expect(find.text('C-051'), findsOneWidget);

    await tester.tap(find.text('Acme 51'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('customers-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
    await tester.pumpAndSettle();

    expect(queries.last.page, 1);
    expect(find.text('C-001'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('customers-page-info')))
          .data,
      'Page 1 / 1',
    );
    await drainToasts(tester);
  });

  testWidgets('Enter opens the editor and Delete asks before removing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('customers-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);

    await tester.tap(find.text('Acme 2'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    // 英文复数：一条用 entry。
    expect(find.textContaining('Delete 1 entry?'), findsOneWidget);
    await tester.tap(find.widgetWithText(Button, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(deletes, isEmpty);
  });

  testWidgets('RTL direction keeps the list laid out', (tester) async {
    await pump(tester, textDirection: TextDirection.rtl);
    expect(tester.takeException(), isNull);
    expect(find.text('C-001'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('C-001'))),
      TextDirection.rtl,
    );
    // 选择与复制在 RTL 下仍按可见顺序工作。
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('customers-copy')));
    await tester.pumpAndSettle();
    expect(clipboard.last, startsWith('C-001	Acme 1'));
    await drainToasts(tester);
  });

  testWidgets('200% text scale keeps the page usable', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester, size: const Size(1280, 800));
    expect(tester.takeException(), isNull);
    expect(find.text('C-001'), findsOneWidget);
  });

  testWidgets('the smallest logical window still shows rows', (tester) async {
    // 1280x720 @200% DPI：DPI 矩阵里最小的逻辑窗口。
    await pump(tester, size: const Size(640, 360));
    expect(tester.takeException(), isNull);
    expect(find.text('C-001'), findsOneWidget);
    expect(find.byKey(const ValueKey('customers-page-info')), findsOneWidget);
  });
}
