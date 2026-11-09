// 真实桌面窗口 + 真实 Rust 库下的键盘焦点与 P02 生命周期 / 内存证据。
// 由 scripts/integration-check.ps1 以独立进程、隔离 KEEL_DATA_DIR 运行；不能改用
// 根 `flutter test`（那里没有动态库与真实窗口）。不使用系统剪贴板：只读复制按钮的
// 可用性，不按 Ctrl+C。
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/app.dart';
import 'package:keel/src/rust/api/app.dart' as app;
import 'package:keel/src/rust/api/audit.dart' as audit;
import 'package:keel/src/rust/api/backup.dart' as backup;
import 'package:keel/src/rust/api/customers.dart' as customers;
import 'package:keel/src/rust/frb_generated.dart';
import 'package:keel/ui/pages/audit_page.dart';
import 'package:keel/ui/pages/backup_page.dart';
import 'package:keel/ui/pages/diagnostics_page.dart';

import 'support/isolation.dart';

/// 审计每页 50 条；120 条 customer.create 正好三页，用来验证翻页。
const _seedCount = 120;
const _pageSize = 50;
const _rssBudgetBytes = 300 * 1024 * 1024;
const _rounds = 5;

String _code(int i) => 'IT-${i.toString().padLeft(3, '0')}';

audit.AuditQuery _auditQuery(String keyword, {int page = 1}) =>
    audit.AuditQuery(
      keyword: keyword,
      startAtMs: null,
      endAtMsExclusive: null,
      sort: const [],
      page: page,
      pageSize: _pageSize,
    );

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  String? reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('等待超时：${reason ?? finder.describeMatch(Plurality.many)}');
}

Future<void> _waitGone(
  WidgetTester tester,
  Finder finder, {
  String? reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('等待消失超时：${reason ?? finder.describeMatch(Plurality.many)}');
}

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(child: KeelApp(locale: Locale('en'))),
  );
  await tester.pump();
  // 登录门禁是异步读取的：外壳出现才算启动完成。
  await _waitFor(tester, find.byType(MenuBar), reason: '外壳启动');
}

/// 侧栏同一 kind 会同时出现在“模块”和“最近访问”里，取模块组的第一项。
Future<void> _openPage(WidgetTester tester, String kind) async {
  final nav = find.byKey(ValueKey('nav-$kind')).first;
  await tester.ensureVisible(nav);
  await tester.pump();
  await tester.tap(nav);
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _closeActiveTab(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump(const Duration(milliseconds: 50));
}

/// Ctrl+W 只在焦点落在外壳子树内时才到得了外壳快捷键（实测：焦点停在
/// 路由 FocusScope 时收不到）。这里对同一个关闭请求做有界重试；页面最终
/// 必须真的关闭，否则用例失败，不放宽断言。
Future<void> _closeTab(
  WidgetTester tester,
  Finder gone, {
  String? reason,
}) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    await _closeActiveTab(tester);
    await tester.pump(const Duration(milliseconds: 150));
    if (gone.evaluate().isEmpty) return;
  }
  fail('标签未能关闭：${reason ?? gone.describeMatch(Plurality.many)}');
}

Future<void> _tapKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 50));
}

Finder _copyRowButton() => find.widgetWithText(Button, 'Copy selected row');

bool _copyRowEnabled(WidgetTester tester) =>
    tester.widget<Button>(_copyRowButton()).onPressed != null;

/// 选中行有背景色；只看离单元格最近的 Container（行容器），避免读到面板底色。
String? _highlightedRow(WidgetTester tester, List<String> codes) {
  for (final code in codes) {
    final cell = find.text(code);
    if (cell.evaluate().isEmpty) continue;
    final containers = find
        .ancestor(of: cell.first, matching: find.byType(Container))
        .evaluate();
    if (containers.isEmpty) continue;
    final decoration = (containers.first.widget as Container).decoration;
    if (decoration is BoxDecoration && decoration.color != null) return code;
  }
  return null;
}

bool _commandEnabled(WidgetTester tester, String id) =>
    tester.widget<IconButton>(find.byKey(ValueKey('command-$id'))).onPressed !=
    null;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String backupName;

  setUpAll(() async {
    await requireIntegrationIsolation();
    await RustLib.init();
    await app.initDatabase();

    // 真实 Rust 写入：先落一份真实备份（供备份页键盘用例），再写 120 个往来单位，
    // 每个产生一条 customer.create 审计。顺序决定审计默认排序下的页边界。
    final created = await backup.createBackup();
    backupName = created.name;
    for (var i = 0; i < _seedCount; i++) {
      await customers.createCustomer(
        request: customers.SaveCustomerRequest(
          code: _code(i),
          name: 'Integration customer $i',
          kind: 'customer',
          phone: '',
          email: '',
          active: true,
          note: '',
        ),
      );
    }
    final seeded = await audit.listAuditLogs(
      query: _auditQuery('customer.create'),
    );
    expect(seeded.total, _seedCount, reason: '种子审计行数');
    debugPrint(
      '[interaction] seeded=$_seedCount auditTotal=${seeded.total} '
      'backup=$backupName',
    );
  });

  testWidgets('真实按键：审计表选择、模态覆盖与备份恢复确认', (tester) async {
    await _pumpApp(tester);
    await _openPage(tester, 'audit');
    await _waitFor(tester, _copyRowButton(), reason: '审计表工具条');
    await _waitFor(tester, find.text(_code(119)), reason: '审计首页第一行');

    // 默认排序 at DESC, id DESC：页 1 = IT-119 … IT-070。
    final pageOne = [for (var i = 119; i >= 70; i--) _code(i)];

    // 1. 点行进入表格焦点：选中态用复制按钮可用性 + 行背景色断言（不读私有状态）。
    await tester.tap(find.text(_code(119)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_copyRowEnabled(tester), isTrue, reason: '点击后应有选中行');
    expect(_highlightedRow(tester, pageOne), _code(119), reason: '点击选中行');

    // 2. ↓ 向下移动一行。
    await _tapKey(tester, LogicalKeyboardKey.arrowDown);
    expect(_highlightedRow(tester, pageOne), _code(118), reason: '↓ 后一行');
    expect(_copyRowEnabled(tester), isTrue);

    await _tapKey(tester, LogicalKeyboardKey.arrowDown);
    expect(_highlightedRow(tester, pageOne), _code(117), reason: '↓↓ 再一行');

    // 3. ↑ 回到上一行。
    await _tapKey(tester, LogicalKeyboardKey.arrowUp);
    expect(_highlightedRow(tester, pageOne), _code(118), reason: '↑ 回上一行');

    // 4. End / Home 跳到本页首末行。
    await _tapKey(tester, LogicalKeyboardKey.end);
    expect(_highlightedRow(tester, pageOne), _code(70), reason: 'End 到本页末行');
    await _tapKey(tester, LogicalKeyboardKey.home);
    expect(_highlightedRow(tester, pageOne), _code(119), reason: 'Home 回本页首行');

    // 5. Escape 清除选择。
    await _tapKey(tester, LogicalKeyboardKey.escape);
    expect(_highlightedRow(tester, pageOne), isNull, reason: 'Esc 清除选中');
    expect(_copyRowEnabled(tester), isFalse, reason: 'Esc 后复制按钮禁用');

    // 6. Ctrl+K 打开页面搜索：模态覆盖期间方向键不得改动被覆盖的表格。
    await _tapKey(tester, LogicalKeyboardKey.arrowDown);
    expect(_highlightedRow(tester, pageOne), _code(119), reason: '重新选中首行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    final pageSearch = find.byType(ContentDialog);
    await _waitFor(tester, pageSearch, reason: '页面搜索浮层');
    await _tapKey(tester, LogicalKeyboardKey.arrowDown);
    await _tapKey(tester, LogicalKeyboardKey.end);
    expect(
      _highlightedRow(tester, pageOne),
      _code(119),
      reason: '模态覆盖期间表格不应响应方向键',
    );

    // Esc 关闭浮层（真机实测：ContentDialog 路由可被 Esc 取消）。
    await _tapKey(tester, LogicalKeyboardKey.escape);
    await _waitGone(tester, pageSearch, reason: 'Esc 关闭页面搜索浮层');
    debugPrint('[interaction] ctrlK_closed_by_escape=true');
    expect(tester.takeException(), isNull);

    // 7. 焦点回到可用状态：方向键继续驱动表格。
    await _tapKey(tester, LogicalKeyboardKey.arrowDown);
    expect(_highlightedRow(tester, pageOne), _code(118), reason: '关闭浮层后 ↓ 生效');
    await _tapKey(tester, LogicalKeyboardKey.escape);
    expect(_highlightedRow(tester, pageOne), isNull);

    // 8. 关闭审计标签后按键不再误触已销毁页面。
    await _closeTab(
      tester,
      find.byType(AuditPage, skipOffstage: false),
      reason: '审计标签关闭',
    );
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.escape,
    ]) {
      await _tapKey(tester, key);
    }
    expect(find.text('Copy selected row'), findsNothing);
    expect(_highlightedRow(tester, pageOne), isNull);
    expect(tester.takeException(), isNull, reason: '关闭后按键不应抛异常');

    // 9. 备份页：真实备份行上的键盘选择与 Enter 恢复确认（取消，不登记恢复）。
    await _openPage(tester, 'backup');
    await _waitFor(tester, find.text(backupName), reason: '备份列表行');
    expect(
      _commandEnabled(tester, 'backup.restore'),
      isFalse,
      reason: '未选中时禁用',
    );

    await tester.tap(find.text(backupName));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_commandEnabled(tester, 'backup.restore'), isTrue, reason: '选中后启用');

    // 只有一行：↓/↑ 仍停在同一条，Escape 清除。
    await _tapKey(tester, LogicalKeyboardKey.arrowDown);
    expect(
      _commandEnabled(tester, 'backup.restore'),
      isTrue,
      reason: '↓ 后仍是该行',
    );
    await _tapKey(tester, LogicalKeyboardKey.arrowUp);
    expect(
      _commandEnabled(tester, 'backup.restore'),
      isTrue,
      reason: '↑ 后仍是该行',
    );

    // Enter 打开恢复确认；取消后不得登记恢复。
    await _tapKey(tester, LogicalKeyboardKey.enter);
    await _waitFor(tester, find.text('Restore from backup?'), reason: '恢复确认');
    final cancel = find.descendant(
      of: find.byType(ContentDialog),
      matching: find.widgetWithText(Button, 'Cancel'),
    );
    await tester.tap(cancel);
    await _waitGone(tester, find.text('Restore from backup?'), reason: '确认取消');
    await _waitGone(
      tester,
      find.textContaining('in progress'),
      reason: '取消后忙状态清空',
    );
    expect(await backup.pendingRestore(), isNull, reason: '取消不登记恢复');

    await _tapKey(tester, LogicalKeyboardKey.escape);
    expect(
      _commandEnabled(tester, 'backup.restore'),
      isFalse,
      reason: 'Esc 清除选中',
    );
    // 没有选中行时 Enter 不应再弹确认。
    await _tapKey(tester, LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Restore from backup?'), findsNothing);
    await _closeTab(
      tester,
      find.byType(BackupPage, skipOffstage: false),
      reason: '备份标签关闭',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('P02：五轮打开/筛选/翻页/关闭的 RSS 采样与无遗留状态', (tester) async {
    await _pumpApp(tester);
    final rss = <int>[ProcessInfo.currentRss];
    debugPrint('[p02] round=0 rss=${rss.last}');

    for (var round = 1; round <= _rounds; round++) {
      // 打开审计标签。
      await _openPage(tester, 'audit');
      await _waitFor(tester, _copyRowButton(), reason: '第 $round 轮审计表');

      // 改筛选：keyword=IT-1 只命中 target IT-100..IT-119 共 20 条 → 只有 1 页。
      // 用“页数变化”作为筛选真正生效的可观察量，避免把旧的 3 页页脚当成新结果。
      final search = find
          .descendant(
            of: find.byType(AuditPage),
            matching: find.byType(TextBox),
          )
          .first;
      await tester.enterText(search, 'IT-1');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Search'));
      await _waitFor(
        tester,
        find.textContaining('Page 1 of 1'),
        reason: '第 $round 轮筛选后只剩 1 页',
      );

      // 重置筛选回到 122 条 = 3 页，再翻到第 2 页并回到第 1 页。
      await tester.tap(find.widgetWithText(Button, 'Reset all filters'));
      await _waitFor(
        tester,
        find.textContaining('Page 1 of 3'),
        reason: '第 $round 轮重置后 3 页',
      );
      // 窗口比 640 布局矮，页脚要先滚进可视区。
      await tester.ensureVisible(find.text('Next'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await _waitFor(
        tester,
        find.textContaining('Page 2 of 3'),
        reason: '第 $round 轮第 2 页',
      );
      await tester.ensureVisible(find.text('Previous'));
      await tester.pump();
      await tester.tap(find.text('Previous'));
      await _waitFor(
        tester,
        find.textContaining('Page 1 of 3'),
        reason: '第 $round 轮回到第 1 页',
      );
      expect(tester.takeException(), isNull);

      // 选中首行把焦点交给表格，再用 Ctrl+W 关闭审计标签。
      // 实测首轮焦点停在外壳外的路由 FocusScope（见日志），快捷键收不到。
      if (round == 1) {
        debugPrint(
          '[p02] focus_before_row_tap=${FocusManager.instance.primaryFocus}',
        );
      }
      await tester.tap(find.text(_code(119)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_copyRowEnabled(tester), isTrue, reason: '第 $round 轮行点击生效');
      await _closeTab(
        tester,
        find.byType(AuditPage, skipOffstage: false),
        reason: '第 $round 轮审计标签关闭',
      );

      // 打开并关闭备份页：点行把焦点交给列表，再 Ctrl+W。
      await _openPage(tester, 'backup');
      await _waitFor(tester, find.byType(BackupPage), reason: '第 $round 轮备份页');
      await _waitFor(tester, find.text(backupName), reason: '第 $round 轮备份行');
      await tester.tap(find.text(backupName));
      await tester.pump(const Duration(milliseconds: 100));
      await _closeTab(
        tester,
        find.byType(BackupPage, skipOffstage: false),
        reason: '第 $round 轮备份标签关闭',
      );

      // 打开并关闭诊断页：点搜索框把焦点落回页面内，再 Ctrl+W。
      await _openPage(tester, 'diagnostics');
      await _waitFor(
        tester,
        find.byType(DiagnosticsPage),
        reason: '第 $round 轮诊断页',
      );
      await tester.pump(const Duration(milliseconds: 200));
      if (round == 1) {
        debugPrint(
          '[p02] diag_focus_before=${FocusManager.instance.primaryFocus}',
        );
      }
      await tester.tap(find.byType(TextBox).first);
      await tester.pump(const Duration(milliseconds: 100));
      await _closeTab(
        tester,
        find.byType(DiagnosticsPage, skipOffstage: false),
        reason: '第 $round 轮诊断标签关闭',
      );

      // 每轮结束：无遗留忙状态、无异常。设置保存等短活动允许先结束再断言。
      await _waitGone(
        tester,
        find.textContaining('in progress'),
        reason: '第 $round 轮遗留忙状态',
        timeout: const Duration(seconds: 10),
      );
      expect(
        find.textContaining('in progress'),
        findsNothing,
        reason: '第 $round 轮遗留忙状态',
      );
      expect(tester.takeException(), isNull, reason: '第 $round 轮异常');

      rss.add(ProcessInfo.currentRss);
      debugPrint('[p02] round=$round rss=${rss.last}');
    }

    // 页面可重新打开：再开一次审计、选中首行并关闭。
    await _openPage(tester, 'audit');
    await _waitFor(tester, _copyRowButton(), reason: '第 5 轮后重新打开审计');
    await tester.tap(find.text(_code(119)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_copyRowEnabled(tester), isTrue, reason: '重新打开后仍可选行');
    await _closeTab(
      tester,
      find.byType(AuditPage, skipOffstage: false),
      reason: '收尾关闭审计',
    );

    final growth = rss.last - rss.first;
    debugPrint(
      '[p02] rss_series=$rss first=${rss.first} last=${rss.last} '
      'growth=$growth maxRss=${ProcessInfo.maxRss}',
    );
    expect(app.appStatus().databaseReady, isTrue);
    expect(
      growth,
      lessThan(_rssBudgetBytes),
      reason: 'RSS 序列 $rss（末轮比首轮增长 $growth 字节）',
    );
    expect(tester.takeException(), isNull);
  });
}
