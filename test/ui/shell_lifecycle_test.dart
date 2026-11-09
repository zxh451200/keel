import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/close_guards.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/ui_page.dart';

class _ExportFixture extends AuditExportNotifier {
  @override
  AuditExportState build() => const AuditExportState();

  void busy(bool value) => state = AuditExportState(starting: value);
}

class _Probe extends StatefulWidget {
  const _Probe(this.id, this.disposed);
  final String id;
  final List<String> disposed;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void dispose() {
    widget.disposed.add(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('${widget.id} content');
}

void main() {
  const user = UserInfo(name: 'local', role: 'admin', permissions: []);
  late ProviderContainer container;
  late List<String> disposed;

  setUp(() {
    disposed = [];
    container = ProviderContainer(
      overrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(version: 'test', databaseReady: true),
        ),
        authStatusProvider.overrideWith(
          (ref) async => const AuthStatusDto(
            loginRequired: false,
            hasPassword: false,
            locked: false,
          ),
        ),
        currentUserProvider.overrideWith((ref) async => user),
        usersProvider.overrideWith((ref) async => const [user]),
        startupRestoreProvider.overrideWith(
          (ref) async => const StartupRestoreStatus(outcome: 'none'),
        ),
        auditExportProvider.overrideWith(_ExportFixture.new),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: KeelShell(
            pages: [
              UiPage(
                kind: 'first',
                title: (_) => 'First fixture',
                icon: FluentIcons.list,
                builder: (_, _) => _Probe('first', disposed),
              ),
              UiPage(
                kind: 'second',
                title: (_) => 'Second fixture',
                icon: FluentIcons.list,
                builder: (_, _) => _Probe('second', disposed),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String name) async {
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
  }

  Future<void> closeAll(WidgetTester tester) async {
    await tester.tap(find.text('File').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close all tabs'));
    await tester.pump();
  }

  for (final throws in [false, true]) {
    testWidgets('batch refusal/exception preserves every page ($throws)', (
      tester,
    ) async {
      await pumpShell(tester);
      await open(tester, 'First fixture');
      await open(tester, 'Second fixture');
      final calls = <String>[];
      container.read(closeGuardsProvider.notifier)
        ..register('first', () async {
          calls.add('first');
          return true;
        })
        ..register('second', () async {
          calls.add('second');
          if (throws) throw StateError('fixture rejection');
          return false;
        });
      await closeAll(tester);
      await tester.pumpAndSettle();
      expect(calls, ['first', 'second']);
      expect(disposed, isEmpty);
      expect(find.text('first content', skipOffstage: false), findsOneWidget);
      expect(find.text('second content', skipOffstage: false), findsOneWidget);
    });
  }

  testWidgets('closing an earlier sibling preserves the other page instance', (
    tester,
  ) async {
    await pumpShell(tester);
    await open(tester, 'First fixture');
    await open(tester, 'Second fixture');
    final hidden = tester.element(
      find.text('first content', skipOffstage: false),
    );
    expect(TickerMode.valuesOf(hidden).enabled, isFalse);
    expect(Focus.of(hidden).canRequestFocus, isFalse);
    await open(tester, 'First fixture');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    for (final element
        in find
            .descendant(
              of: find.byType(IndexedStack),
              matching: find.byType(KeyedSubtree),
            )
            .evaluate()) {
      debugPrint(
        'DBG child ${element.widget.runtimeType} key=${element.widget.hashCode} '
        'el=${element.hashCode} '
        'child=${(element.widget as KeyedSubtree).child.runtimeType}',
      );
    }
    expect(disposed, ['first']);
    expect(find.text('second content'), findsOneWidget);
    final context = tester.element(find.text('second content'));
    expect(TickerMode.valuesOf(context).enabled, isTrue);
  });

  testWidgets('pending close blocks duplicate exit and keeps all pages', (
    tester,
  ) async {
    await pumpShell(tester);
    await open(tester, 'First fixture');
    final confirmation = Completer<bool>();
    var calls = 0;
    container.read(closeGuardsProvider.notifier).register('first', () {
      calls++;
      return confirmation.future;
    });
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(calls, 1);
    confirmation.complete(false);
    await tester.pumpAndSettle();
    expect(disposed, isEmpty);
  });

  testWidgets('exit checks export busy without an audit or tasks tab', (
    tester,
  ) async {
    await pumpShell(tester);
    final exporter =
        container.read(auditExportProvider.notifier) as _ExportFixture;
    exporter.busy(true);
    await tester.pump();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(find.text('1 operation in progress'), findsOneWidget);
    exporter.busy(false);
    await tester.pumpAndSettle();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
  });

  testWidgets('export started during confirmation cancels exit', (
    tester,
  ) async {
    await pumpShell(tester);
    await open(tester, 'First fixture');
    final confirmation = Completer<bool>();
    container
        .read(closeGuardsProvider.notifier)
        .register('first', () => confirmation.future);
    final exit = tester.binding.handleRequestAppExit();
    await tester.pump();
    (container.read(auditExportProvider.notifier) as _ExportFixture).busy(true);
    confirmation.complete(true);
    expect(await exit, AppExitResponse.cancel);
    expect(disposed, isEmpty);
    (container.read(auditExportProvider.notifier) as _ExportFixture).busy(
      false,
    );
    await tester.pumpAndSettle();
  });
}
