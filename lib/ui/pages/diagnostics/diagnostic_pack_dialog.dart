import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/diagnostics.dart';

/// 选择类别、检查脱敏快照、确认写入；成功返回导出位置。
class DiagnosticPackDialog extends ConsumerStatefulWidget {
  const DiagnosticPackDialog({super.key});

  @override
  ConsumerState<DiagnosticPackDialog> createState() =>
      _DiagnosticPackDialogState();
}

class _DiagnosticPackDialogState extends ConsumerState<DiagnosticPackDialog> {
  bool _runtime = true;
  bool _events = false;
  bool _busy = false;
  DiagnosticPackPreview? _preview;
  Object? _error;

  bool get _allowed => hasPermission(
    ref.read(currentUserProvider).asData?.value,
    'diagnostics.export',
  );

  void _cancel() {
    if (!_busy) Navigator.of(context).pop();
  }

  void _change({bool? runtime, bool? events}) {
    if (_busy) return;
    setState(() {
      _runtime = runtime ?? _runtime;
      _events = events ?? _events;
      _preview = null;
      _error = null;
    });
  }

  Future<void> _prepare() async {
    if (_busy || !_allowed || (!_runtime && !_events)) return;
    final activity = ref.read(diagnosticPackBusyProvider.notifier);
    if (!activity.begin()) return;
    final service = ref.read(diagnosticPackServiceProvider);
    final request = DiagnosticPackRequest(
      categories: [if (_runtime) 'runtime', if (_events) 'recent_events'],
    );
    setState(() {
      _busy = true;
      _preview = null;
      _error = null;
    });
    try {
      final preview = await service.prepare(request);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      activity.finish();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final preview = _preview;
    if (_busy || !_allowed || preview == null) return;
    final activity = ref.read(diagnosticPackBusyProvider.notifier);
    if (!activity.begin()) return;
    final service = ref.read(diagnosticPackServiceProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    String? path;
    try {
      path = await service.export(preview.previewId);
    } catch (error) {
      if (mounted) {
        setState(() {
          _preview = null;
          _error = error;
        });
      }
    } finally {
      activity.finish();
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && path != null) Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final user = ref.watch(currentUserProvider);
    final allowed = hasPermission(user.asData?.value, 'diagnostics.export');
    final preview = _preview;
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    return PopScope<String>(
      canPop: !_busy,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
        child: ContentDialog(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          title: Text(t.diagExportTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.diagPackSelectionHint),
                const SizedBox(height: 8),
                _Check(
                  checked: _runtime,
                  title: t.diagPackRuntime,
                  subtitle: t.diagPackRuntimeHint,
                  onChanged: _busy ? null : (v) => _change(runtime: v),
                ),
                const SizedBox(height: 8),
                _Check(
                  checked: _events,
                  title: t.diagPackEvents,
                  subtitle: t.diagPackEventsHint,
                  onChanged: _busy ? null : (v) => _change(events: v),
                ),
                if (!_runtime && !_events)
                  Text(
                    t.diagPackChooseCategory,
                    style: theme.typography.caption?.copyWith(
                      color: const Color(0xFFC42B1C),
                    ),
                  ),
                if (!allowed && user.hasValue)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      t.errPermission,
                      style: theme.typography.caption?.copyWith(
                        color: const Color(0xFFC42B1C),
                      ),
                    ),
                  ),
                if (_busy) ...[
                  const SizedBox(height: 8),
                  const ProgressBar(),
                  const SizedBox(height: 8),
                  Text(t.diagPackWorking),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      errorText(t, error),
                      style: TextStyle(color: const Color(0xFFC42B1C)),
                    ),
                  ),
                  Text(t.diagPackReprepareHint),
                ],
                if (preview != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    height: 1,
                    color: (theme.typography.body?.color ?? Colors.black)
                        .withValues(alpha: 0.12),
                  ),
                  const SizedBox(height: 10),
                  Text(t.diagExportHint, style: TextStyle(color: muted)),
                  Text(t.diagPackEventCount(preview.eventCount)),
                  Text(t.diagPackSnapshotHint, style: TextStyle(color: muted)),
                  const SizedBox(height: 8),
                  SelectableText(
                    preview.content,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            Button(
              onPressed: _busy ? null : _cancel,
              child: Text(t.actionCancel),
            ),
            Button(
              onPressed: _busy || !allowed || (!_runtime && !_events)
                  ? null
                  : () => unawaited(_prepare()),
              child: Text(t.diagPackPreview),
            ),
            FilledButton(
              onPressed: _busy || !allowed || preview == null
                  ? null
                  : () => unawaited(_export()),
              child: Text(t.diagExportConfirm),
            ),
          ],
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({
    required this.checked,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  final bool checked;
  final String title;
  final String subtitle;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          checked: checked,
          onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              Text(
                subtitle,
                style: theme.typography.caption?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
