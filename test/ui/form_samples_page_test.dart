import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/features/form_samples/sample_parsers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/pages/form_samples_page.dart';

Future<void> _pump(
  WidgetTester tester, {
  String formatLocale = 'en_US',
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: FluentApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FormSamplesPage(formatLocale: formatLocale),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _pickDateEntry = Key('form-sample-pick-date');
const _pickEntry = Key('form-sample-pick-date-time');
const _pickApply = Key('ui-date-picker-apply');
const _pickCancel = Key('ui-date-picker-cancel');
const _pickCalendar = Key('ui-date-picker-calendar');
const _pickTime = Key('ui-date-picker-time');

Future<void> _pumpPicker(
  WidgetTester tester, {
  String formatLocale = 'en_US',
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await _pump(tester, formatLocale: formatLocale, locale: locale);
}

Future<void> _openPicker(WidgetTester tester, {Key entry = _pickEntry}) async {
  final finder = find.byKey(entry);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

String _dateText(WidgetTester tester) =>
    tester.widget<TextBox>(find.byType(TextBox).at(3)).controller!.text;

String _dateTimeText(WidgetTester tester) =>
    tester.widget<TextBox>(find.byType(TextBox).at(4)).controller!.text;

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

  testWidgets('date-time field exposes a labelled picker entry', (
    tester,
  ) async {
    await _pumpPicker(tester);
    expect(find.byKey(_pickEntry), findsOneWidget);
    expect(find.byIcon(FluentIcons.date_time), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Pick date and time' &&
            widget.properties.button == true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('picker opens an inline calendar and 24-hour clock', (
    tester,
  ) async {
    await _pumpPicker(tester);
    await _openPicker(tester);
    expect(find.byType(ContentDialog), findsOneWidget);
    expect(find.byKey(_pickCalendar), findsOneWidget);
    expect(find.byKey(_pickTime), findsOneWidget);
    expect(
      tester.widget<TimePicker>(find.byKey(_pickTime)).hourFormat,
      HourFormat.HH,
    );
  });

  testWidgets('cancel keeps the manual date-time text', (tester) async {
    await _pumpPicker(tester);
    final field = find.byType(TextBox).at(4);
    await tester.ensureVisible(field);
    await tester.enterText(field, '11/11/2026 14:30');
    await tester.pumpAndSettle();
    await _openPicker(tester);
    await tester.tap(find.byKey(_pickCancel));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
    expect(_dateTimeText(tester), '11/11/2026 14:30');
  });

  testWidgets('applying fills a US-format value that round-trips', (
    tester,
  ) async {
    await _pumpPicker(tester);
    await _openPicker(tester);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsNothing);
    final text = _dateTimeText(tester);
    expect(text, matches(RegExp(r'^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$')));
    final parsed = parseSampleDateTime(text, 'en_US');
    expect(parsed, isNotNull);
    expect(formatSampleDateTime(parsed!, 'en_US'), text);
  });

  testWidgets('picking replaces an invalid manual value', (tester) async {
    await _pumpPicker(tester);
    final field = find.byType(TextBox).at(4);
    await tester.ensureVisible(field);
    await tester.enterText(field, '123');
    await tester.pumpAndSettle();
    await _openPicker(tester);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    expect(_dateTimeText(tester), isNot('123'));
    expect(parseSampleDateTime(_dateTimeText(tester), 'en_US'), isNotNull);
  });

  testWidgets('picked value follows zh_CN and a later format change', (
    tester,
  ) async {
    await _pumpPicker(
      tester,
      formatLocale: 'zh_CN',
      locale: const Locale('zh'),
    );
    await _openPicker(tester);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    final zh = _dateTimeText(tester);
    expect(zh, matches(RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$')));
    expect(parseSampleDateTime(zh, 'zh_CN'), isNotNull);

    await _pump(tester, formatLocale: 'en_GB', locale: const Locale('zh'));
    final gb = _dateTimeText(tester);
    expect(gb, matches(RegExp(r'^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$')));
    expect(parseSampleDateTime(gb, 'en_GB'), isNotNull);
  });

  testWidgets('calendar date field has its own picker without a clock', (
    tester,
  ) async {
    await _pumpPicker(tester);
    expect(find.byKey(_pickDateEntry), findsOneWidget);
    expect(find.byIcon(FluentIcons.calendar), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Pick date',
      ),
      findsOneWidget,
    );
    await _openPicker(tester, entry: _pickDateEntry);
    expect(find.byType(ContentDialog), findsOneWidget);
    expect(find.byKey(_pickCalendar), findsOneWidget);
    expect(find.byType(TimePicker), findsNothing);
  });

  testWidgets('applying the date picker fills only the calendar date field', (
    tester,
  ) async {
    await _pumpPicker(tester);
    await _openPicker(tester, entry: _pickDateEntry);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    final text = _dateText(tester);
    expect(text, matches(RegExp(r'^\d{2}/\d{2}/\d{4}$')));
    expect(parseSampleDate(text, 'en_US'), isNotNull);
    expect(_dateTimeText(tester), isEmpty);
  });

  testWidgets('date picker replaces an invalid manual date', (tester) async {
    await _pumpPicker(tester);
    final field = find.byType(TextBox).at(3);
    await tester.ensureVisible(field);
    await tester.enterText(field, '123');
    await tester.pumpAndSettle();
    await _openPicker(tester, entry: _pickDateEntry);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    expect(_dateText(tester), isNot('123'));
    expect(parseSampleDate(_dateText(tester), 'en_US'), isNotNull);
  });

  testWidgets('both date fields use the shared picker in zh_CN', (
    tester,
  ) async {
    await _pumpPicker(
      tester,
      formatLocale: 'zh_CN',
      locale: const Locale('zh'),
    );
    await _openPicker(tester, entry: _pickDateEntry);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    expect(_dateText(tester), matches(RegExp(r'^\d{4}/\d{2}/\d{2}$')));
    expect(parseSampleDate(_dateText(tester), 'zh_CN'), isNotNull);

    await _openPicker(tester);
    expect(find.byType(TimePicker), findsOneWidget);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    expect(
      _dateTimeText(tester),
      matches(RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$')),
    );
    expect(parseSampleDateTime(_dateTimeText(tester), 'zh_CN'), isNotNull);
  });

  testWidgets(
    'date fields show concrete examples that follow the format locale',
    (tester) async {
      await _pumpPicker(tester);
      expect(find.text('e.g. 11/11/2026'), findsOneWidget);
      expect(find.text('e.g. 11/11/2026 14:30'), findsOneWidget);

      await _pump(tester, formatLocale: 'zh_CN', locale: const Locale('zh'));
      expect(find.text('例如 2026/11/11'), findsOneWidget);
      expect(find.text('例如 2026/11/11 14:30'), findsOneWidget);
    },
  );

  testWidgets('leaving a filled invalid date validates immediately', (
    tester,
  ) async {
    await _pumpPicker(tester);
    final field = find.byType(TextBox).at(3);
    await tester.ensureVisible(field);
    await tester.enterText(field, '123');
    await tester.pumpAndSettle();
    // Still editing: no premature error while the caret is in the field.
    expect(find.textContaining('Enter a valid calendar date'), findsNothing);

    final next = tester.widget<TextBox>(find.byType(TextBox).at(4));
    next.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a valid calendar date'), findsOneWidget);

    await tester.enterText(field, '11/11/2026');
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a valid calendar date'), findsNothing);
    expect(parseSampleDate(_dateText(tester), 'en_US'), isNotNull);
  });

  testWidgets('tabbing through empty fields does not show errors', (
    tester,
  ) async {
    await _pumpPicker(tester);
    final first = tester.widget<TextBox>(find.byType(TextBox).at(0));
    final second = tester.widget<TextBox>(find.byType(TextBox).at(1));
    first.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    second.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter nonblank text'), findsNothing);
  });

  testWidgets('filling from the picker clears an immediate error', (
    tester,
  ) async {
    await _pumpPicker(tester);
    final field = find.byType(TextBox).at(3);
    await tester.ensureVisible(field);
    await tester.enterText(field, '123');
    tester
        .widget<TextBox>(find.byType(TextBox).at(4))
        .focusNode!
        .requestFocus();
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a valid calendar date'), findsOneWidget);

    await _openPicker(tester, entry: _pickDateEntry);
    await tester.tap(find.byKey(_pickApply));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a valid calendar date'), findsNothing);
    expect(parseSampleDate(_dateText(tester), 'en_US'), isNotNull);
  });
}
