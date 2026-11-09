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
import 'package:trina_grid/trina_grid.dart';

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
  late List<List<CustomerUpdate>> batchUpdates;
  late List<List<int>> deletes;
  late List<(List<int>, bool)> activeCalls;
  late List<String?> clipboard;
  late List<CustomerItem> rows;
  Object? writeError;
  String? pasteText;
  late int updateAttempts;
  late int batchAttempts;

  List<CustomerItem> all() => [for (var i = 1; i <= 120; i++) _item(i)];

  /// 假写入要真的落到 `rows`，刷新后才能看到新值（与真实数据库一致）。
  void applyRequests(List<CustomerUpdate> requests) {
    for (final update in requests) {
      final index = rows.indexWhere((item) => item.id == update.id);
      if (index < 0) continue;
      final item = rows[index];
      final request = update.request;
      rows[index] = CustomerItem(
        id: item.id,
        code: request.code,
        name: request.name,
        kind: request.kind,
        phone: request.phone,
        email: request.email,
        active: request.active,
        note: request.note,
        updatedAt: item.updatedAt + 1,
        updatedBy: item.updatedBy,
      );
    }
  }

  Future<void> drainToasts(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  /// fluent 的 InfoBar 先挂一个空占位，过一小段动画时间才显示内容。
  Future<void> revealToast(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 500));

  /// 网格内的单元格编辑器（搜索框在网格外，不会被选中）。
  Finder cellEditor() => find.descendant(
    of: find.byType(TrinaGrid),
    matching: find.byType(EditableText),
  );

  /// 先点一次选中行，再点同一格进入编辑（行选择模式下的常规手势）。
  Future<void> startEditing(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> sendPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

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
                updateAttempts += 1;
                if (writeError != null) throw writeError!;
                updates.add((id, request));
                applyRequests([CustomerUpdate(id: id, request: request)]);
              },
              updateMany: (requests) async {
                batchAttempts += 1;
                if (writeError != null) throw writeError!;
                batchUpdates.add(requests);
                applyRequests(requests);
                return requests.length;
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
    batchUpdates = [];
    deletes = [];
    activeCalls = [];
    clipboard = [];
    rows = all();
    writeError = null;
    pasteText = null;
    updateAttempts = 0;
    batchAttempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String?);
          }
          if (call.method == 'Clipboard.getData') {
            return pasteText == null
                ? null
                : <String, dynamic>{'text': pasteText};
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
    expect(find.byType(TrinaGrid), findsOneWidget);
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

  testWidgets('Shift+arrow extends the selection from the anchor', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const ValueKey('customers-copy')));
    await tester.pumpAndSettle();
    final rows = clipboard.last!.split('\r\n');
    expect(rows, hasLength(3));
    expect(rows.first, startsWith('C-001\tAcme 1'));
    expect(rows.last, startsWith('C-003\tAcme 3'));
    await drainToasts(tester);
  });

  testWidgets('Home and End move the cursor to the first and last row', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Acme 5'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('customers-copy')));
    await tester.pumpAndSettle();
    expect(clipboard.last, startsWith('C-001\tAcme 1'));
    await drainToasts(tester);

    // 复制按钮拿走了焦点，回到表格后再试 End。
    await tester.tap(find.text('Acme 5'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('customers-copy')));
    await tester.pumpAndSettle();
    expect(clipboard.last, startsWith('C-050\tAcme 50'));
    await drainToasts(tester);
  });

  testWidgets('the smallest logical window still shows rows', (tester) async {
    // 1280x720 @200% DPI：DPI 矩阵里最小的逻辑窗口。
    await pump(tester, size: const Size(640, 360));
    expect(tester.takeException(), isNull);
    expect(find.text('C-001'), findsOneWidget);
    expect(find.byKey(const ValueKey('customers-page-info')), findsOneWidget);
  });

  testWidgets('editing one cell sends a full update and shows the new value', (
    tester,
  ) async {
    await pump(tester);
    await startEditing(tester, 'C-001');
    expect(cellEditor(), findsOneWidget);

    await tester.enterText(cellEditor(), 'C-901');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // 一次提交一整条记录：未改动字段保留该行原值（含隐藏的类型/启用/备注）。
    expect(updates, hasLength(1));
    final (id, request) = updates.single;
    expect(id, 1);
    expect(request.code, 'C-901');
    expect(request.name, 'Acme 1');
    expect(request.kind, 'customer');
    expect(request.phone, '');
    expect(request.email, '');
    expect(request.active, isTrue);
    expect(request.note, '');
    expect(batchAttempts, 0);
    // 刷新后网格显示新值，且仍停留在第 1 页。
    expect(find.text('C-901'), findsOneWidget);
    expect(queries.last.page, 1);
  });

  testWidgets('a rejected cell edit rolls back once and reports the error', (
    tester,
  ) async {
    writeError = const ApiError(
      code: 'KEEL-VALIDATION',
      message: '编号格式不正确',
      correlationId: '',
    );
    await pump(tester);
    await startEditing(tester, 'C-001');
    await tester.enterText(cellEditor(), 'bad code!');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(updateAttempts, 1);
    expect(updates, isEmpty);
    // 单元格退回旧值，且没有二次提交。
    expect(find.text('C-001'), findsOneWidget);
    expect(find.text('bad code!'), findsNothing);
    await revealToast(tester);
    expect(
      find.text('Invalid input. Please check and try again.'),
      findsOneWidget,
    );
    await drainToasts(tester);
    expect(updateAttempts, 1);
  });

  testWidgets('a viewer cannot open the cell editor or paste', (tester) async {
    await pump(tester, user: _viewer);
    await startEditing(tester, 'C-001');
    expect(cellEditor(), findsNothing);

    pasteText = 'Hacked\t555-0101';
    await sendPaste(tester);
    expect(batchAttempts, 0);
    expect(batchUpdates, isEmpty);
    expect(updateAttempts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paste writes a 2x2 block through one atomic update', (
    tester,
  ) async {
    pasteText = 'Pasted A\t555-0101\r\nPasted B\t555-0202';
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    // 当前单元格从编号列右移到名称列，粘贴块从名称列开始。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    await sendPaste(tester);

    expect(batchAttempts, 1);
    expect(batchUpdates, hasLength(1));
    final requests = batchUpdates.single;
    expect(requests, hasLength(2));
    // 第 1 行：名称/电话被替换，编号/邮箱保留原值。
    expect(requests[0].id, 1);
    expect(requests[0].request.code, 'C-001');
    expect(requests[0].request.name, 'Pasted A');
    expect(requests[0].request.phone, '555-0101');
    expect(requests[0].request.email, '');
    expect(requests[0].request.kind, 'customer');
    expect(requests[0].request.active, isTrue);
    // 第 2 行同理，隐藏字段按该行自己的原值拼。
    expect(requests[1].id, 2);
    expect(requests[1].request.code, 'C-002');
    expect(requests[1].request.name, 'Pasted B');
    expect(requests[1].request.phone, '555-0202');
    expect(requests[1].request.kind, 'supplier');
    // 成功后提示条数并刷新网格。
    await revealToast(tester);
    expect(find.text('Pasted into 2 entries.'), findsOneWidget);
    expect(find.text('Pasted A'), findsOneWidget);
    await drainToasts(tester);
  });

  testWidgets('paste rejects an oversized or empty clipboard', (tester) async {
    pasteText = 'x' * ((1 << 20) + 1);
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    await sendPaste(tester);
    expect(batchAttempts, 0);
    await revealToast(tester);
    expect(
      find.text('Paste canceled: the clipboard is larger than 1 MiB.'),
      findsOneWidget,
    );
    await drainToasts(tester);

    // 空剪贴板（mock 返回 null）直接返回，不崩溃也不发请求。
    pasteText = null;
    await sendPaste(tester);
    expect(tester.takeException(), isNull);
    expect(batchAttempts, 0);
  });

  testWidgets('paste rejects read-only starts, wide blocks and page overflow', (
    tester,
  ) async {
    // 单列内容：只有“起点不可编辑”能拦住它，范围提示不会与宽度越界混淆。
    pasteText = 'Blocked';
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    // 编号 → 名称 → 类型 → 电话 → 邮箱 → 状态：状态列不可编辑。
    for (var i = 0; i < 5; i += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    await sendPaste(tester);
    expect(batchAttempts, 0);
    await revealToast(tester);
    expect(
      find.text(
        'Paste canceled: start in an editable column and stay within '
        'code, name, phone and email.',
      ),
      findsOneWidget,
    );
    await drainToasts(tester);

    // 从邮箱列开始的两列块超出可编辑块。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    pasteText = 'a@b.example\tActive';
    await sendPaste(tester);
    expect(batchAttempts, 0);
    await revealToast(tester);
    expect(
      find.textContaining('stay within code, name, phone and email'),
      findsOneWidget,
    );
    await drainToasts(tester);

    // 行数超出当前页：光标移到本页最后一行时再粘贴两行。
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    pasteText = 'One\t555-0101\r\nTwo\t555-0202';
    await sendPaste(tester);
    expect(batchAttempts, 0);
    await revealToast(tester);
    expect(
      find.text(
        'Paste canceled: it would go past the last entry on this page.',
      ),
      findsOneWidget,
    );
    await drainToasts(tester);
  });

  testWidgets('a failed paste leaves the grid untouched and reports it', (
    tester,
  ) async {
    writeError = const ApiError(
      code: 'KEEL-VALIDATION',
      message: '名称不能为空',
      correlationId: '',
    );
    pasteText = 'Pasted A\t555-0101';
    await pump(tester);
    await tester.tap(find.text('Acme 1'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    await sendPaste(tester);

    expect(batchAttempts, 1);
    expect(batchUpdates, isEmpty);
    // 失败不动任何单元格：等成功才刷新，避免半更新。
    expect(find.text('Acme 1'), findsOneWidget);
    expect(find.text('Pasted A'), findsNothing);
    await revealToast(tester);
    expect(
      find.text('Invalid input. Please check and try again.'),
      findsOneWidget,
    );
    await drainToasts(tester);
  });
}
