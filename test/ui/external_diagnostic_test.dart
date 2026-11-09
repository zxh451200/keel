import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/features/diagnostics/state/external_diagnostic_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/diagnostics.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/diagnostics/external_diagnostic_dialog.dart';

void main() {
  const owner = UserInfo(
    name: 'diagnostic-owner',
    role: 'admin',
    permissions: ['diagnostics.export'],
  );
  late ProviderContainer container;
  late Completer<String?> selection;
  Completer<ExternalDiagnosticPreview>? preparation;
  late List<String> reads;
  late List<String> exports;
  late int selections;

  setUp(() {
    // selection 在 open()（fakeAsync zone）内创建：setUp 的真实 zone 会把
    // future 监听器排进真实事件循环，组件测试的假时钟永远不会执行它。
    preparation = null;
    reads = [];
    exports = [];
    selections = 0;
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => owner),
        externalDiagnosticServiceProvider.overrideWithValue(
          ExternalDiagnosticService(
            prepareText: (_) async => throw StateError('unexpected text input'),
            chooseFile: (_, _, _, _) {
              selections++;
              return selection.future;
            },
            prepareFile: (path) async {
              reads.add(path);
              if (preparation != null) return await preparation!.future;
              return const ExternalDiagnosticPreview(
                previewId: 'one-shot',
                content: 'token=[REDACTED]',
                sensitiveCategories: ['token'],
              );
            },
            export: (id) async {
              exports.add(id);
              return 'diagnostics.zip';
            },
          ),
        ),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> open(WidgetTester tester) async {
    selection = Completer<String?>();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
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
            content: Consumer(
              builder: (context, ref, _) {
                return Button(
                  onPressed: () => showExternalDiagnosticDialog(context, ref),
                  child: const Text('Launch'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await container.read(currentUserProvider.future);
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('external-diagnostic-select-file')),
    );
    // An unresolved chooser keeps the progress animation active.
    await tester.pump();
  }

  testWidgets(
    'file selection is single flight and export requires confirmation',
    (tester) async {
      await open(tester);
      expect(selections, 1);
      expect(container.read(diagnosticPackBusyProvider), isTrue);
      await tester.tap(
        find.byKey(const ValueKey('external-diagnostic-select-file')),
      );
      await tester.pump();
      expect(selections, 1);
      selection.complete('/private/input.log');
      await tester.pumpAndSettle();
      expect(reads, ['/private/input.log']);
      expect(exports, isEmpty);
      expect(find.text('token=[REDACTED]'), findsOneWidget);
      expect(find.textContaining('/private/input.log'), findsNothing);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(exports, ['one-shot']);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(container.read(diagnosticPackBusyProvider), isFalse);
      // 导出成功提示约 3 秒后自动关闭；用假时钟走完定时器。
      await tester.pump(const Duration(seconds: 30));
    },
  );

  testWidgets('identity change while preparing discards the late preview', (
    tester,
  ) async {
    preparation = Completer<ExternalDiagnosticPreview>();
    await open(tester);
    selection.complete('/private/input.log');
    await tester.pump();
    expect(reads, ['/private/input.log']);
    container.invalidate(currentUserProvider);
    await tester.pump();
    expect(container.read(diagnosticPackBusyProvider), isTrue);
    preparation!.complete(
      const ExternalDiagnosticPreview(
        previewId: 'stale',
        content: 'late preview',
        sensitiveCategories: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('late preview'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(exports, isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(container.read(diagnosticPackBusyProvider), isFalse);
  });

  testWidgets(
    'preparation failure hides native details and releases busy on close',
    (tester) async {
      preparation = Completer<ExternalDiagnosticPreview>();
      await open(tester);
      selection.complete('/private/input.log');
      await tester.pump();
      preparation!.completeError(StateError('/private/input.log SECRET'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ContentDialog));
      expect(
        find.text(AppLocalizations.of(context).errGeneric),
        findsOneWidget,
      );
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.textContaining('/private/input.log'), findsNothing);
      expect(exports, isEmpty);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(container.read(diagnosticPackBusyProvider), isFalse);
    },
  );

  testWidgets('removed dialog retains busy until file preparation completes', (
    tester,
  ) async {
    preparation = Completer<ExternalDiagnosticPreview>();
    await open(tester);
    selection.complete('/private/input.log');
    await tester.pump();
    expect(reads, ['/private/input.log']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(container.read(diagnosticPackBusyProvider), isTrue);
    preparation!.complete(
      const ExternalDiagnosticPreview(
        previewId: 'disposed',
        content: 'late preview',
        sensitiveCategories: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(exports, isEmpty);
    expect(tester.takeException(), isNull);
    expect(container.read(diagnosticPackBusyProvider), isFalse);
  });

  testWidgets('cancelled chooser does not read or export', (tester) async {
    await open(tester);
    selection.complete(null);
    await tester.pumpAndSettle();
    expect(reads, isEmpty);
    expect(exports, isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(container.read(diagnosticPackBusyProvider), isFalse);
  });

  testWidgets('identity invalidation discards a late selected path', (
    tester,
  ) async {
    await open(tester);
    container.invalidate(currentUserProvider);
    await tester.pump();
    selection.complete('/private/late.log');
    await tester.pumpAndSettle();
    expect(reads, isEmpty);
    expect(exports, isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(container.read(diagnosticPackBusyProvider), isFalse);
  });
}
