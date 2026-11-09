import 'package:fluent_ui/fluent_ui.dart';

import 'grid_column_layout.dart';
import 'grid_column_preferences_provider.dart';

/// Text supplied by the host page so this reusable widget does not depend on
/// the app's generated localization or on a particular grid implementation.
class GridColumnSettingsLabels {
  const GridColumnSettingsLabels({
    required this.title,
    required this.description,
    required this.visible,
    required this.width,
    required this.frozen,
    required this.frozenStart,
    required this.frozenNone,
    required this.frozenEnd,
    required this.moveUp,
    required this.moveDown,
    required this.apply,
    required this.cancel,
    required this.reset,
    required this.invalid,
  });

  final String title;
  final String description;
  final String visible;
  final String width;
  final String frozen;
  final String frozenStart;
  final String frozenNone;
  final String frozenEnd;
  final String moveUp;
  final String moveDown;
  final String apply;
  final String cancel;
  final String reset;
  final String invalid;
}

/// Opens a draft based column settings dialog. Nothing is persisted until the
/// caller saves the returned layout through [GridColumnSettingsController].
Future<GridColumnLayout?> showGridColumnSettingsDialog(
  BuildContext context, {
  required GridColumnLayout initial,
  required GridColumnSettingsLabels labels,
  required String Function(String id) columnTitle,
  bool showFrozen = true,
}) => showDialog<GridColumnLayout>(
  context: context,
  builder: (dialogContext) => GridColumnSettingsDialog(
    initial: initial,
    labels: labels,
    columnTitle: columnTitle,
    showFrozen: showFrozen,
  ),
);

class GridColumnSettingsDialog extends StatefulWidget {
  const GridColumnSettingsDialog({
    super.key,
    required this.initial,
    required this.labels,
    required this.columnTitle,
    this.showFrozen = true,
  });

  final GridColumnLayout initial;
  final GridColumnSettingsLabels labels;
  final String Function(String id) columnTitle;
  final bool showFrozen;

  @override
  State<GridColumnSettingsDialog> createState() =>
      _GridColumnSettingsDialogState();
}

class _GridColumnSettingsDialogState extends State<GridColumnSettingsDialog> {
  late final GridColumnSettingsController _controller =
      GridColumnSettingsController(widget.initial);
  String? _error;

  void _replace(void Function() action) {
    setState(() {
      action();
      _error = null;
    });
  }

  void _apply() {
    try {
      // Reconstructing validates the draft, including the at-least-one-visible
      // invariant, before it crosses the dialog boundary.
      final checked = GridColumnLayout(
        _controller.draft.listId,
        _controller.draft.columns,
      );
      Navigator.of(context).pop(checked);
    } on FormatException {
      setState(() => _error = widget.labels.invalid);
    }
  }

  String _frozenLabel(GridFrozen frozen) => switch (frozen) {
    GridFrozen.start => widget.labels.frozenStart,
    GridFrozen.none => widget.labels.frozenNone,
    GridFrozen.end => widget.labels.frozenEnd,
  };

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final columns = _controller.draft.columns;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
      title: Text(labels.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(labels.description),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: columns.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final column = columns[index];
                final firstInGroup =
                    index == 0 || columns[index - 1].frozen != column.frozen;
                final lastInGroup =
                    index == columns.length - 1 ||
                    columns[index + 1].frozen != column.frozen;
                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color:
                          (FluentTheme.of(context).typography.body?.color ??
                                  Colors.black)
                              .withValues(alpha: 0.12),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(widget.columnTitle(column.id))),
                          Checkbox(
                            checked: column.visible,
                            onChanged: (value) => _replace(() {
                              _controller.update(column.id, visible: value);
                            }),
                            content: Text(labels.visible),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Text('${labels.width}: ${column.width}'),
                          Expanded(
                            child: Slider(
                              min: GridColumnLayout.minWidth.toDouble(),
                              max: GridColumnLayout.maxWidth.toDouble(),
                              divisions:
                                  GridColumnLayout.maxWidth -
                                  GridColumnLayout.minWidth,
                              value: column.width.toDouble(),
                              onChanged: (value) => _replace(() {
                                _controller.update(
                                  column.id,
                                  width: value.round(),
                                );
                              }),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          if (widget.showFrozen) ...[
                            Text('${labels.frozen}: '),
                            DropDownButton(
                              title: Text(_frozenLabel(column.frozen)),
                              items: [
                                for (final frozen in GridFrozen.values)
                                  MenuFlyoutItem(
                                    text: Text(_frozenLabel(frozen)),
                                    onPressed: column.visible
                                        ? () => _replace(() {
                                            _controller.update(
                                              column.id,
                                              frozen: frozen,
                                            );
                                          })
                                        : null,
                                  ),
                              ],
                            ),
                          ],
                          const Spacer(),
                          Button(
                            onPressed: firstInGroup
                                ? null
                                : () => _replace(() {
                                    _controller.reorder(column.id, index - 1);
                                  }),
                            child: Text(labels.moveUp),
                          ),
                          const SizedBox(width: 6),
                          Button(
                            onPressed: lastInGroup
                                ? null
                                : () => _replace(() {
                                    _controller.reorder(column.id, index + 1);
                                  }),
                            child: Text(labels.moveDown),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            InfoBar(severity: InfoBarSeverity.error, title: Text(_error!)),
          ],
        ],
      ),
      actions: [
        Button(
          onPressed: () => _replace(_controller.reset),
          child: Text(labels.reset),
        ),
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(labels.cancel),
        ),
        FilledButton(onPressed: _apply, child: Text(labels.apply)),
      ],
    );
  }
}
