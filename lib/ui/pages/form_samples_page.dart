import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/features/form_samples/sample_parsers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/close_guards.dart';
import 'package:keel/ui/widgets/ui_dialogs.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 本地交互样例：int32、精确 USD、日期时间与枚举的格式化预览。
/// 不写数据库、不调用桥接；语言格式切换时重新格式化已填日期。
class FormSamplesPage extends ConsumerStatefulWidget {
  const FormSamplesPage({super.key, required this.formatLocale});

  final String formatLocale;

  @override
  ConsumerState<FormSamplesPage> createState() => FormSamplesPageState();
}

/// 订阅显示区域并把它作为普通参数传给样例页。
class FormSamplesHost extends ConsumerWidget {
  const FormSamplesHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormSamplesPage(
      formatLocale: ref.watch(effectiveFormatLocaleProvider),
    );
  }
}

class FormSamplesPageState extends ConsumerState<FormSamplesPage> {
  final _fields = List.generate(5, (_) => TextEditingController());
  final _focus = List.generate(5, (i) => FocusNode(debugLabel: 'form.$i'));
  final _fieldKeys = List.generate(5, (_) => GlobalKey());
  final _lastTexts = List.filled(5, '');
  final _staleDates = <int>{};
  SampleChoice _choice = SampleChoice.standard;
  SampleCurrency _currency = SampleCurrency.usd;
  SampleTimeDisplay _timeDisplay = SampleTimeDisplay.systemLocal;
  bool _submitted = false;
  bool _confirming = false;
  int _revision = 0;
  _Preview? _preview;
  CloseGuards? _guards;

  bool get dirty =>
      _fields.any((field) => field.text.isNotEmpty) ||
      _choice != SampleChoice.standard ||
      _currency != SampleCurrency.usd ||
      _timeDisplay != SampleTimeDisplay.systemLocal;

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      field.addListener(_inputChanged);
    }
    _guards = ref.read(closeGuardsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _guards?.register('form_samples', canClose);
    });
  }

  @override
  void dispose() {
    _guards?.unregister('form_samples');
    for (final field in _fields) {
      field.dispose();
    }
    for (final focus in _focus) {
      focus.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FormSamplesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.formatLocale == widget.formatLocale) return;
    for (final i in [3, 4]) {
      final text = _fields[i].text;
      if (text.isEmpty || _staleDates.contains(i)) continue;
      if (i == 3) {
        final date = parseSampleDate(text, oldWidget.formatLocale);
        if (date == null) {
          _staleDates.add(i);
        } else {
          _fields[i].text = date.format(widget.formatLocale);
        }
      } else {
        final date = parseSampleDateTime(text, oldWidget.formatLocale);
        if (date == null) {
          _staleDates.add(i);
        } else {
          _fields[i].text = formatSampleDateTime(date, widget.formatLocale);
        }
      }
    }
    _revision++;
    _preview = null;
    setState(() {});
  }

  /// 非破坏性检查；成功预览仍算未保存内容。
  Future<bool> canClose() async {
    if (!mounted || _confirming || ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    if (!dirty) return true;
    final revision = _revision;
    final t = AppLocalizations.of(context);
    setState(() => _confirming = true);
    try {
      final discard = await showConfirmDialog(
        context,
        title: t.formSampleDiscardTitle,
        message: t.formSampleDiscardMessage,
        confirmLabel: t.actionDiscard,
        cancelLabel: t.actionKeepEditing,
        danger: true,
      );
      return mounted &&
          discard &&
          revision == _revision &&
          ModalRoute.of(context)?.isCurrent != false;
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  // Controller edits also invalidate approval, including programmatic changes
  // while a discard dialog is open.
  void _inputChanged() {
    if (!mounted) return;
    var changed = false;
    for (var i = 0; i < _fields.length; i++) {
      final text = _fields[i].text;
      if (_lastTexts[i] != text) {
        _lastTexts[i] = text;
        changed = true;
      }
    }
    // Selection and caret movement do not change the draft.
    if (!changed) return;
    setState(() {
      _revision++;
      _preview = null;
    });
  }

  void _changed(int? field) {
    if (!_canAct) return;
    setState(() {
      if (field != null) _staleDates.remove(field);
      _revision++;
      _preview = null;
    });
  }

  Future<void> _reset() async {
    if (!_canAct) return;
    if (!await canClose() || !_canAct) return;
    setState(() {
      for (final field in _fields) {
        field.clear();
      }
      _choice = SampleChoice.standard;
      _currency = SampleCurrency.usd;
      _timeDisplay = SampleTimeDisplay.systemLocal;
      _submitted = false;
      _preview = null;
      _staleDates.clear();
      _revision++;
    });
  }

  List<String> _labels(AppLocalizations t) => [
    t.formSampleText,
    t.formSampleInteger,
    t.formSampleAmount,
    t.formSampleDate,
    t.formSampleDateTime,
  ];

  String? _error(int i, AppLocalizations t) {
    final value = _fields[i].text;
    if (_staleDates.contains(i)) return t.formSampleLocaleChanged;
    return switch (i) {
      0 =>
        value.trim().isEmpty || value.runes.length > 80
            ? t.formSampleTextError
            : null,
      1 => parseSampleInteger(value) == null ? t.formSampleIntegerError : null,
      2 =>
        parseSampleMoney(value, widget.formatLocale) == null
            ? t.formSampleAmountError
            : null,
      3 =>
        parseSampleDate(value, widget.formatLocale) == null
            ? t.formSampleDateError(sampleDatePattern(widget.formatLocale))
            : null,
      _ =>
        parseSampleDateTime(value, widget.formatLocale) == null
            ? t.formSampleDateTimeError(
                '${sampleDatePattern(widget.formatLocale)} HH:mm',
              )
            : null,
    };
  }

  bool get _canAct =>
      mounted &&
      !_confirming &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  void _locateField(int i) {
    if (!_canAct) return;
    _focus[i].requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canAct || !_focus[i].hasFocus) return;
      final target = _fieldKeys[i].currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.25);
      }
    });
  }

  void _showPreview() {
    if (!_canAct) return;
    final t = AppLocalizations.of(context);
    setState(() => _submitted = true);
    for (var i = 0; i < 5; i++) {
      if (_error(i, t) != null) {
        _locateField(i);
        return;
      }
    }
    setState(
      () => _preview = _Preview(
        _fields[0].text.trim(),
        parseSampleInteger(_fields[1].text)!,
        parseSampleMoney(_fields[2].text, widget.formatLocale)!,
        parseSampleDate(_fields[3].text, widget.formatLocale)!,
        parseSampleDateTime(_fields[4].text, widget.formatLocale)!.toUtc(),
        _choice,
        _currency,
        _timeDisplay,
      ),
    );
  }

  String _choiceLabel(AppLocalizations t, SampleChoice choice) =>
      choice == SampleChoice.standard
      ? t.formSampleStandard
      : t.formSamplePriority;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final labels = _labels(t);
    final errors = [
      for (var i = 0; i < 5; i++)
        if (_error(i, t) case final error?) '${labels[i]}: $error',
    ];
    final pattern = sampleDatePattern(widget.formatLocale);
    final preview = _preview;
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    final labelStyle = theme.typography.body?.copyWith(fontSize: 13);

    Widget field(int i, {String? hint}) {
      final error = _submitted ? _error(i, t) : null;
      return Column(
        key: _fieldKeys[i],
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(labels[i], style: labelStyle),
          const SizedBox(height: 6),
          TextBox(
            controller: _fields[i],
            focusNode: _focus[i],
            enabled: !_confirming,
            placeholder: hint ?? labels[i],
            onChanged: (_) => _changed(i),
            onSubmitted: (_) {
              if (!_canAct) return;
              if (i == 4) {
                _showPreview();
              } else {
                _locateField(i + 1);
              }
            },
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                style: theme.typography.caption?.copyWith(
                  color: const Color(0xFFC42B1C),
                ),
              ),
            ),
        ],
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _reset},
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiPageHeader(
                title: t.formSamplesTitle,
                subtitle: t.formSampleLocalNotice,
              ),
              const SizedBox(height: 14),
              Text(
                t.formSampleInternationalInputRules(
                  widget.formatLocale,
                  pattern,
                ),
                style: theme.typography.caption?.copyWith(color: muted),
              ),
              if (_staleDates.isNotEmpty) ...[
                const SizedBox(height: 8),
                UiNotice(
                  message: t.formSampleLocaleChanged,
                  severity: InfoBarSeverity.warning,
                ),
              ],
              if (_submitted && errors.isNotEmpty) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: UiNotice(
                    message: '${t.formErrorSummary}\n${errors.join('\n')}',
                    severity: InfoBarSeverity.error,
                  ),
                ),
                for (var i = 0; i < 5; i++)
                  if (_error(i, t) != null)
                    Button(
                      onPressed: _confirming ? null : () => _locateField(i),
                      child: Text(labels[i]),
                    ),
              ],
              const SizedBox(height: 14),
              UiPanel(
                header: Text(t.formSampleValuesSection),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      field(i),
                      if (i < 2) const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              UiPanel(
                header: Text(t.formSampleDatesSection),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field(3, hint: pattern),
                    const SizedBox(height: 12),
                    field(4, hint: '$pattern HH:mm'),
                    const SizedBox(height: 8),
                    Text(
                      t.formSampleTimeDisplayNotice,
                      style: theme.typography.caption?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              UiPanel(
                header: Text(t.formSampleChoiceSection),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ComboField<SampleChoice>(
                      label: t.formSampleChoice,
                      value: _choice,
                      items: [
                        for (final choice in SampleChoice.values)
                          ComboBoxItem(
                            value: choice,
                            child: Text(_choiceLabel(t, choice)),
                          ),
                      ],
                      onChange: _confirming
                          ? null
                          : (choice) {
                              if (!_canAct || choice == null) return;
                              _choice = choice;
                              _changed(null);
                            },
                    ),
                    const SizedBox(height: 12),
                    _ComboField<SampleCurrency>(
                      label: t.formSampleCurrency,
                      value: _currency,
                      items: [
                        for (final currency in SampleCurrency.values)
                          ComboBoxItem(
                            value: currency,
                            child: Text(currency.name.toUpperCase()),
                          ),
                      ],
                      onChange: _confirming
                          ? null
                          : (currency) {
                              if (!_canAct || currency == null) return;
                              if (currency == _currency) return;
                              _currency = currency;
                              _changed(null);
                            },
                    ),
                    const SizedBox(height: 12),
                    _ComboField<SampleTimeDisplay>(
                      label: t.formSampleTimeDisplay,
                      value: _timeDisplay,
                      items: [
                        for (final display in SampleTimeDisplay.values)
                          ComboBoxItem(
                            value: display,
                            child: Text(
                              display == SampleTimeDisplay.utc
                                  ? t.formSampleUtc
                                  : t.formSampleSystemLocal,
                            ),
                          ),
                      ],
                      onChange: _confirming
                          ? null
                          : (display) {
                              if (!_canAct || display == null) return;
                              if (display == _timeDisplay) return;
                              _timeDisplay = display;
                              _changed(null);
                            },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _confirming ? null : _showPreview,
                    child: Text(t.formSamplePreviewAction),
                  ),
                  Button(
                    onPressed: _confirming ? null : _reset,
                    child: Text(t.formSampleResetAction),
                  ),
                ],
              ),
              if (preview != null) ...[
                const SizedBox(height: 12),
                UiPanel(
                  header: Text(t.formSamplePreviewNotice),
                  child: Semantics(
                    liveRegion: true,
                    child: SelectableText(
                      t.formSampleInternationalPreview(
                        preview.text,
                        NumberFormat.decimalPattern(widget.formatLocale)
                            .format(preview.integer),
                        formatSampleCurrency(
                          preview.minor,
                          widget.formatLocale,
                          preview.currency,
                        ),
                        preview.minor.toString(),
                        preview.date.format(widget.formatLocale),
                        formatSampleInstant(
                          preview.instantUtc,
                          widget.formatLocale,
                          preview.timeDisplay,
                        ),
                        preview.timeDisplay == SampleTimeDisplay.utc
                            ? t.formSampleUtc
                            : t.formSampleSystemLocal,
                        preview.instantUtc.millisecondsSinceEpoch.toString(),
                        _choiceLabel(t, preview.choice),
                      ),
                      style: theme.typography.body,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ComboField<T> extends StatelessWidget {
  const _ComboField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChange,
  });

  final String label;
  final T value;
  final List<ComboBoxItem<T>> items;
  final ValueChanged<T?>? onChange;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.typography.body?.copyWith(fontSize: 13)),
        const SizedBox(height: 6),
        ComboBox<T>(
          value: value,
          isExpanded: true,
          items: items,
          onChanged: onChange,
        ),
      ],
    );
  }
}

class _Preview {
  const _Preview(
    this.text,
    this.integer,
    this.minor,
    this.date,
    this.instantUtc,
    this.choice,
    this.currency,
    this.timeDisplay,
  );
  final String text;
  final int integer;
  final int minor;
  final SampleCalendarDate date;
  final DateTime instantUtc;
  final SampleCurrency currency;
  final SampleTimeDisplay timeDisplay;
  final SampleChoice choice;
}
