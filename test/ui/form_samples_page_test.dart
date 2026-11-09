import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/pages/form_samples_page.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: FluentApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FormSamplesPage(formatLocale: 'en_US'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('invalid preview scrolls to first error with live summary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester);
    final preview = find.widgetWithText(FilledButton, 'Generate local preview');
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    final first = tester.widget<TextBox>(find.byType(TextBox).first);
    expect(first.focusNode!.hasFocus, isTrue);
    expect(find.byType(TextBox).first.hitTestable(), findsOneWidget);
    expect(
      tester
          .widgetList<Semantics>(find.byType(Semantics))
          .any((widget) => widget.properties.liveRegion == true),
      isTrue,
    );
  });

  testWidgets('Tab, Shift Tab and Enter traverse fields', (tester) async {
    await _pump(tester);
    final first = tester.widget<TextBox>(find.byType(TextBox).at(0));
    final second = tester.widget<TextBox>(find.byType(TextBox).at(1));
    first.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(second.focusNode!.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(first.focusNode!.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(second.focusNode!.hasFocus, isTrue);
  });

  testWidgets(
    'Escape confirms once and rejects approval after controller edits',
    (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextBox).first, 'Draft');
      final first = tester.widget<TextBox>(find.byType(TextBox).first);
      final reset = tester
          .widget<Button>(find.widgetWithText(Button, 'Reset draft'))
          .onPressed!;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      reset();
      expect(find.byType(ContentDialog), findsOneWidget);
      first.controller!.text = 'Changed';
      first.controller!.text = 'Draft';
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(first.controller!.text, 'Draft');
      reset();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(first.controller!.text, isEmpty);
    },
  );
}
