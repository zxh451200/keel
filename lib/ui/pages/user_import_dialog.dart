import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/users/state/user_import_controller.dart';
import 'package:keel/features/users/state/user_import_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/error.dart';

Future<void> _waitForIdle(UserImportController controller) async {
  if (!controller.busy) return;
  final idle = Completer<void>();
  void check() {
    if (!controller.busy && !idle.isCompleted) idle.complete();
  }

  controller.addListener(check);
  try {
    check();
    await idle.future;
  } finally {
    controller.removeListener(check);
  }
}

Future<void> showUserImportDialog(BuildContext context) async {
  if (!context.mounted ||
      ModalRoute.of(context)?.isCurrent == false ||
      !TickerMode.valuesOf(context).enabled) {
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  bool permitted() {
    final user = container.read(currentUserProvider);
    return !user.isLoading &&
        !user.hasError &&
        hasPermission(user.asData?.value, 'users.manage');
  }

  if (!permitted() || container.read(userImportOpenProvider)) return;
  final service = container.read(userImportServiceProvider);
  final gate = container.read(userImportOpenProvider.notifier);
  ModalRoute<dynamic>? route;
  var active = true;
  final controller = UserImportController(
    allowed: () =>
        active &&
        context.mounted &&
        route?.isCurrent == true &&
        TickerMode.valuesOf(context).enabled &&
        permitted(),
    prepare: service.prepare,
    run: (ticket, bytes) async {
      final count = await service.run(ticket, bytes);
      container.invalidate(usersProvider);
      return count;
    },
    cancel: service.cancel,
    readProgress: service.readProgress,
    isCancellation: (error) =>
        error is ApiError && error.code == 'KEEL-CANCELLED',
  );
  final subscriptions = <ProviderSubscription<dynamic>>[];
  gate.state = true;
  try {
    subscriptions.add(
      container.listen(currentUserProvider, (_, _) => controller.invalidate()),
    );
    subscriptions.add(
      container.listen(
        userImportServiceProvider,
        (_, _) => controller.invalidate(),
      ),
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        route = ModalRoute.of(dialogContext);
        return _UserImportDialog(controller: controller);
      },
    );
  } finally {
    active = false;
    controller.invalidate();
    await _waitForIdle(controller);
    await route?.completed;
    for (final subscription in subscriptions) {
      subscription.close();
    }
    controller.dispose();
    gate.state = false;
  }
}

class _UserImportDialog extends StatefulWidget {
  const _UserImportDialog({required this.controller});
  final UserImportController controller;
  @override
  State<_UserImportDialog> createState() => _UserImportDialogState();
}

class _UserImportDialogState extends State<_UserImportDialog> {
  final _input = TextEditingController();
  int? _created;
  bool _submitting = false;
  UserImportController get c => widget.controller;
  bool get _current =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      TickerMode.valuesOf(context).enabled;

  @override
  void initState() {
    super.initState();
    c.addListener(_update);
  }

  void _update() {
    if (c.stale) {
      _input.clear();
      _created = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_update);
    _input.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (!_current ||
        c.stale ||
        c.busy ||
        _submitting ||
        c.preview == null ||
        _created != null) {
      return;
    }
    setState(() => _submitting = true);
    final count = await c.confirm();
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!c.stale) _created = count;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final locked = c.busy || _submitting;
    final editable = !locked && !c.stale && _created == null;
    final message = _created != null
        ? t.userImportDone(_created!)
        : c.stale
        ? t.userImportStale
        : switch (c.error) {
            UserImportError.validation => t.errValidation,
            UserImportError.failed => t.errGeneric,
            UserImportError.cancelFailed => t.userImportCancelFailed,
            UserImportError.cancelled => t.userImportCancelled,
            null => null,
          };
    return PopScope(
      canPop: !locked,
      child: ContentDialog(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 740),
        title: Text(t.userImportTitle),
        content: SizedBox(
          width: 680,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.userImportHint),
              const SizedBox(height: 8),
              TextBox(
                key: const ValueKey('user-import-input'),
                controller: _input,
                enabled: editable,
                maxLines: 5,
                placeholder: t.userImportInput,
                inputFormatters: [
                  TextInputFormatter.withFunction(
                    (old, next) =>
                        next.text.length <= 1048576 &&
                            utf8.encode(next.text).length <= 1048576
                        ? next
                        : old,
                  ),
                ],
                onChanged: (_) {
                  if (_current && editable) c.changed();
                },
              ),
              const SizedBox(height: 8),
              Text(t.userImportPreviewHint),
              if (message != null)
                Semantics(liveRegion: true, child: Text(message)),
              if (locked) ...[
                Text(
                  c.progress == null
                      ? t.userImportWaiting
                      : t.userImportProgress(
                          c.progress!.processed,
                          c.progress!.total,
                        ),
                ),
                // Processing all rows is not confirmation of COMMIT.
                if (c.progress case final progress?
                    when progress.processed < progress.total)
                  ProgressBar(
                    value: 100.0 * progress.processed / progress.total,
                  )
                else
                  const ProgressBar(),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    c.preview ?? '',
                    key: const ValueKey('user-import-preview'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          Button(
            key: const ValueKey('user-import-close'),
            onPressed: locked
                ? null
                : () {
                    if (_current && c.canClose && !_submitting) {
                      Navigator.of(context).pop();
                    }
                  },
            child: Text(t.actionClose),
          ),
          if (c.busy)
            Button(
              key: const ValueKey('user-import-cancel'),
              onPressed: c.cancelRequested
                  ? null
                  : () {
                      if (_current && c.busy) unawaited(c.requestCancel());
                    },
              child: Text(t.actionCancel),
            ),
          Button(
            key: const ValueKey('user-import-prepare'),
            onPressed: !editable
                ? null
                : () {
                    if (_current && !c.busy && !c.stale) {
                      c.previewText(_input.text);
                    }
                  },
            child: Text(t.userImportPreviewAction),
          ),
          FilledButton(
            key: const ValueKey('user-import-confirm'),
            onPressed: editable && c.preview != null ? _confirm : null,
            child: Text(t.userImportConfirmAction),
          ),
        ],
      ),
    );
  }
}
