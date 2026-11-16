import 'package:fluent_ui/fluent_ui.dart';

import 'package:keel/ui/tokens.dart';

/// Shared date / date-time pickers for the whole app (fluent_ui 4.17.0).
///
/// The dialog only picks a [DateTime]; formatting and validation are injected
/// by the caller, so every screen keeps its own parsing rules (locale patterns,
/// year range, DST gaps) and its text field stays the single source of truth.
/// The inline calendar matches the audit page's date-range dialog.
final DateTime uiDatePickerMinDate = DateTime(1900);
final DateTime uiDatePickerMaxDate = DateTime(2100, 12, 31, 23, 59, 59);

/// TextBox suffix: a calendar icon button with a screen-reader label.
class UiDatePickerButton extends StatelessWidget {
  const UiDatePickerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = FluentIcons.date_time,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: IconButton(icon: Icon(icon, size: 16), onPressed: onPressed),
    );
  }
}

/// Opens the shared picker. Returns null when cancelled.
///
/// [format] builds the preview text shown above the actions; [validate] gates
/// the apply button, so an invalid value can never be written back.
/// Set [withTime] to false for calendar-only values (no timezone, no clock).
Future<DateTime?> showUiDatePicker({
  required BuildContext context,
  required String title,
  required String notice,
  required String cancelLabel,
  required String applyLabel,
  required String invalidLabel,
  required DateTime initial,
  required String Function(DateTime) format,
  required bool Function(DateTime) validate,
  bool withTime = false,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (context) => _UiDatePickerDialog(
      title: title,
      notice: notice,
      cancelLabel: cancelLabel,
      applyLabel: applyLabel,
      invalidLabel: invalidLabel,
      initial: initial,
      format: format,
      validate: validate,
      withTime: withTime,
    ),
  );
}

/// An inclusive calendar-date range as picked by [showUiDateRangePicker].
class UiDateRange {
  const UiDateRange({this.start, this.end});
  final DateTime? start;
  final DateTime? end;
}

/// Result of [showUiDateRangePicker].
///
/// [clear] is true only when the user pressed the explicit clear action;
/// the range is then meaningless and must be ignored. [start]/[end] are
/// calendar dates (midnight local, no clock component).
class UiDateRangePick {
  const UiDateRangePick({this.start, this.end, this.clear = false});
  final DateTime? start;
  final DateTime? end;
  final bool clear;
}

/// Opens the shared date-range picker. Returns null when cancelled.
///
/// Labels and range formatting are injected by the caller, same contract as
/// [showUiDatePicker]. When both ends are picked, [format] builds the preview
/// line shown above the actions.
Future<UiDateRangePick?> showUiDateRangePicker({
  required BuildContext context,
  required String title,
  required String notice,
  required String cancelLabel,
  required String clearLabel,
  required String applyLabel,
  required String Function(DateTime start, DateTime end) format,
  UiDateRange? initial,
}) {
  return showDialog<UiDateRangePick>(
    context: context,
    builder: (context) => _UiDateRangePickerDialog(
      title: title,
      notice: notice,
      cancelLabel: cancelLabel,
      clearLabel: clearLabel,
      applyLabel: applyLabel,
      format: format,
      initial: initial ?? const UiDateRange(),
    ),
  );
}

class _UiDateRangePickerDialog extends StatefulWidget {
  const _UiDateRangePickerDialog({
    required this.title,
    required this.notice,
    required this.cancelLabel,
    required this.clearLabel,
    required this.applyLabel,
    required this.format,
    required this.initial,
  });

  final String title;
  final String notice;
  final String cancelLabel;
  final String clearLabel;
  final String applyLabel;
  final String Function(DateTime start, DateTime end) format;
  final UiDateRange initial;

  @override
  State<_UiDateRangePickerDialog> createState() =>
      _UiDateRangePickerDialogState();
}

class _UiDateRangePickerDialogState extends State<_UiDateRangePickerDialog> {
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _start = widget.initial.start;
    _end = widget.initial.end;
  }

  void _pick(CalendarSelectionData data) {
    setState(() {
      _start = data.startDate;
      _end = data.endDate;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final theme = FluentTheme.of(context);
    final caption = theme.typography.caption?.copyWith(
      color: tokens.secondaryText,
    );
    final complete = _start != null && _end != null;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 430, maxHeight: 620),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.notice, style: caption),
            const SizedBox(height: 8),
            SizedBox(
              height: 370,
              child: CalendarView(
                key: const Key('ui-date-range-picker-calendar'),
                selectionMode: CalendarViewSelectionMode.range,
                // 只传打开时的初值：CalendarView 在 didUpdateWidget 里会把
                // initialStart/End 的变化再回灌给 onSelectionChanged，回传
                // 选取结果会在 build 期形成 setState 重入。
                initialStart: widget.initial.start,
                initialEnd: widget.initial.end,
                minDate: uiDatePickerMinDate,
                maxDate: uiDatePickerMaxDate,
                locale: Localizations.localeOf(context),
                onSelectionChanged: _pick,
              ),
            ),
            if (complete) ...[
              const SizedBox(height: 8),
              Text(widget.format(_start!, _end!), style: tokens.displayNumber),
            ],
          ],
        ),
      ),
      actions: [
        Button(
          key: const Key('ui-date-range-picker-clear'),
          onPressed: () =>
              Navigator.of(context).pop(const UiDateRangePick(clear: true)),
          child: Text(widget.clearLabel),
        ),
        Button(
          key: const Key('ui-date-range-picker-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          key: const Key('ui-date-range-picker-apply'),
          onPressed: complete
              ? () =>
                    Navigator.of(context)
                        .pop(UiDateRangePick(start: _start, end: _end))
              : null,
          child: Text(widget.applyLabel),
        ),
      ],
    );
  }
}

class _UiDatePickerDialog extends StatefulWidget {
  const _UiDatePickerDialog({
    required this.title,
    required this.notice,
    required this.cancelLabel,
    required this.applyLabel,
    required this.invalidLabel,
    required this.initial,
    required this.format,
    required this.validate,
    required this.withTime,
  });

  final String title;
  final String notice;
  final String cancelLabel;
  final String applyLabel;
  final String invalidLabel;
  final DateTime initial;
  final String Function(DateTime) format;
  final bool Function(DateTime) validate;
  final bool withTime;

  @override
  State<_UiDatePickerDialog> createState() => _UiDatePickerDialogState();
}

class _UiDatePickerDialogState extends State<_UiDatePickerDialog> {
  late DateTime _selected = widget.initial;

  void _pickDate(CalendarSelectionData data) {
    final date = data.startDate;
    if (date == null) return;
    setState(
      () => _selected = DateTime(
        date.year,
        date.month,
        date.day,
        _selected.hour,
        _selected.minute,
      ),
    );
  }

  void _pickTime(DateTime time) {
    setState(
      () => _selected = DateTime(
        _selected.year,
        _selected.month,
        _selected.day,
        time.hour,
        time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final theme = FluentTheme.of(context);
    final caption = theme.typography.caption?.copyWith(
      color: tokens.secondaryText,
    );
    final value = widget.format(_selected);
    final valid = widget.validate(_selected);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 430, maxHeight: 760),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.notice, style: caption),
            const SizedBox(height: 12),
            SizedBox(
              // The month view needs ~334px; 350 keeps it from overflowing.
              height: 350,
              child: CalendarView(
                key: const Key('ui-date-picker-calendar'),
                selectionMode: CalendarViewSelectionMode.single,
                // 只传打开时的初值：CalendarView 在 didUpdateWidget 里会把
                // initialStart 的变化再回灌给 onSelectionChanged，回传选取
                // 结果会在 build 期形成 setState 重入。
                initialStart: widget.initial,
                minDate: uiDatePickerMinDate,
                maxDate: uiDatePickerMaxDate,
                locale: Localizations.localeOf(context),
                onSelectionChanged: _pickDate,
              ),
            ),
            if (widget.withTime) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    FluentIcons.clock,
                    size: 16,
                    color: tokens.secondaryText,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TimePicker(
                      key: const Key('ui-date-picker-time'),
                      selected: _selected,
                      hourFormat: HourFormat.HH,
                      minuteIncrement: 1,
                      onChanged: _pickTime,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (valid)
              Text(value, style: tokens.displayNumber)
            else
              Text(
                widget.invalidLabel,
                style: caption?.copyWith(color: tokens.colors.danger),
              ),
          ],
        ),
      ),
      actions: [
        Button(
          key: const Key('ui-date-picker-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          key: const Key('ui-date-picker-apply'),
          onPressed: valid ? () => Navigator.of(context).pop(_selected) : null,
          child: Text(widget.applyLabel),
        ),
      ],
    );
  }
}
