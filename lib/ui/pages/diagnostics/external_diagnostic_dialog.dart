import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/features/diagnostics/state/external_diagnostic_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/diagnostics.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

enum _Operation { text, file, export }

/// Notifies when the dialog's element unmounts, so a disposed tree cannot
/// leak the busy gate through a dialog future that never completes.
class _DialogUnmountWatcher extends StatefulWidget {
  const _DialogUnmountWatcher({required this.onUnmount, required this.child});

  final VoidCallback onUnmount;
  final Widget child;

  @override
  State<_DialogUnmountWatcher> createState() => _DialogUnmountWatcherState();
}

class _DialogUnmountWatcherState extends State<_DialogUnmountWatcher> {
  @override
  void dispose() {
    widget.onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Activity extends ChangeNotifier {
  Future<void>? pending;
  bool active = true;
  bool stale = false;
  void invalidate() {
    stale = true;
    notifyListeners();
  }
}

/// Owns the busy gate beyond the lifetime of the dialog and its pending call.
Future<void> showExternalDiagnosticDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!context.mounted ||
      ModalRoute.of(context)?.isCurrent == false ||
      !TickerMode.valuesOf(context).enabled) {
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final identity = container.read(currentUserProvider);
  if (identity.isLoading ||
      identity.hasError ||
      !hasPermission(identity.asData?.value, 'diagnostics.export')) {
    return;
  }
  final gate = container.read(diagnosticPackBusyProvider.notifier);
  if (!gate.begin()) return;
  final activity = _Activity();
  final service = container.read(externalDiagnosticServiceProvider);
  final subscriptions = <ProviderSubscription<dynamic>>[];
  ModalRoute<dynamic>? route;
  try {
    subscriptions.add(
      container.listen(currentUserProvider, (_, _) {
        activity.invalidate();
      }),
    );
    subscriptions.add(
      container.listen(externalDiagnosticServiceProvider, (_, _) {
        activity.invalidate();
      }),
    );
    // A disposed tree never pops the dialog route, so its future would hang
    // forever and leak the busy gate. The hidden watcher completes when the
    // dialog's element unmounts, which covers both normal pop and disposal.
    final dialogDisposed = Completer<void>();
    await Future.any<void>([
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          route = ModalRoute.of(dialogContext);
          return _DialogUnmountWatcher(
            onUnmount: () {
              if (!dialogDisposed.isCompleted) {
                dialogDisposed.complete();
              }
            },
            child: _ExternalDiagnosticDialog(
              activity: activity,
              service: service,
            ),
          );
        },
      ),
      dialogDisposed.future,
    ]);
    activity.active = false;
    await activity.pending;
    if (context.mounted) {
      await route?.completed;
    }
  } finally {
    activity.active = false;
    await activity.pending;
    for (final subscription in subscriptions) {
      subscription.close();
    }
    gate.finish();
    activity.dispose();
  }
}

class _ExternalDiagnosticDialog extends StatefulWidget {
  const _ExternalDiagnosticDialog({
    required this.activity,
    required this.service,
  });
  final _Activity activity;
  final ExternalDiagnosticService service;
  @override
  State<_ExternalDiagnosticDialog> createState() =>
      _ExternalDiagnosticDialogState();
}

class _ExternalDiagnosticDialogState extends State<_ExternalDiagnosticDialog> {
  final _input = TextEditingController();
  ExternalDiagnosticPreview? _preview;
  var _working = false;
  var _revision = 0;
  String? _error;
  bool get _current =>
      mounted &&
      widget.activity.active &&
      !widget.activity.stale &&
      ModalRoute.of(context)?.isCurrent != false &&
      TickerMode.valuesOf(context).enabled;

  @override
  void initState() {
    super.initState();
    widget.activity.addListener(_invalidate);
  }

  void _invalidate() {
    _revision++;
    _input.clear();
    if (mounted) setState(() => _preview = null);
  }

  @override
  void dispose() {
    _revision++;
    widget.activity.removeListener(_invalidate);
    _input.dispose();
    super.dispose();
  }

  void _start(_Operation kind) {
    if (_working ||
        !_current ||
        (kind == _Operation.export && _preview == null)) {
      return;
    }
    // A synchronous latch also rejects retained button callbacks.
    setState(() {
      _working = true;
      _error = null;
    });
    final operation = _operate(kind);
    widget.activity.pending = operation;
  }

  Future<void> _operate(_Operation kind) async {
    final generation = _revision;
    final t = AppLocalizations.of(context);
    try {
      if (kind == _Operation.export) {
        final preview = _preview!;
        // Consume the local handle before invoking Rust's one-shot export.
        setState(() => _preview = null);
        final path = await widget.service.export(preview.previewId);
        if (mounted && _current && generation == _revision) {
          showToast(context, t.diagExportDone(path));
        }
      } else if (kind == _Operation.file) {
        setState(() => _preview = null);
        final path = await widget.service.chooseFile(
          t.externalDiagnosticTitle,
          t.externalDiagnosticInput,
          t.actionCancel,
          t.actionOpen,
        );
        if (!_current || generation != _revision || path == null) return;
        final preview = await widget.service.prepareFile(path);
        if (_current && generation == _revision) {
          _input.clear();
          setState(() => _preview = preview);
        }
      } else {
        final text = _input.text;
        if (text.trim().isEmpty ||
            text.length > 1024 * 1024 ||
            utf8.encode(text).length > 1024 * 1024) {
          if (mounted) setState(() => _error = t.errValidation);
          return;
        }
        setState(() => _preview = null);
        final preview = await widget.service.prepareText(text);
        if (_current && generation == _revision) {
          _input.clear();
          setState(() => _preview = preview);
        }
      }
    } catch (_) {
      // External text, paths and native error details must not be echoed.
      if (_current) {
        setState(() {
          _preview = null;
          _error = t.errGeneric;
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: !_working,
      child: ContentDialog(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 760),
        title: Text(t.externalDiagnosticTitle),
        content: SizedBox(
          width: 740,
          height: 540,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.externalDiagnosticHint),
              const SizedBox(height: 8),
              Button(
                key: const ValueKey('external-diagnostic-select-file'),
                onPressed: _working || widget.activity.stale
                    ? null
                    : () => _start(_Operation.file),
                child: Text('${t.actionOpen} ${t.externalDiagnosticInput}'),
              ),
              const SizedBox(height: 8),
              TextBox(
                controller: _input,
                enabled: !_working,
                maxLines: 5,
                placeholder: t.externalDiagnosticInput,
                onChanged: (_) {
                  _revision++;
                  setState(() {
                    _preview = null;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 8),
              Text(t.externalDiagnosticPreviewHint),
              if (_error != null) Text(_error!),
              if (widget.activity.stale) Text(t.diagPackReprepareHint),
              if (_working) const ProgressBar(),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    _preview?.content ?? '',
                    key: const ValueKey('external-diagnostic-preview'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          Button(
            onPressed: _working ? null : () => Navigator.of(context).pop(),
            child: Text(t.actionClose),
          ),
          Button(
            onPressed: _working || widget.activity.stale
                ? null
                : () => _start(_Operation.text),
            child: Text(t.diagPackPreview),
          ),
          FilledButton(
            onPressed: _working || widget.activity.stale || _preview == null
                ? null
                : () => _start(_Operation.export),
            child: Text(t.diagExportConfirm),
          ),
        ],
      ),
    );
  }
}
