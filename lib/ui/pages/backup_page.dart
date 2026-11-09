import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/backup/backup_actions.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/backup.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 备份与恢复：恢复登记后下次启动生效，旧数据库保留。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  final _scroll = ScrollController(debugLabel: 'backup.list');
  final _listFocus = FocusNode(debugLabel: 'backup.list');
  final Map<String, GlobalKey> _rowKeys = {};

  @override
  void dispose() {
    _scroll.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  List<BackupInfo> get _rows => ref.read(backupsProvider).value ?? const [];

  void _select(String? name) {
    ref.read(backupSelectionProvider.notifier).state = name;
    _listFocus.requestFocus();
    if (name == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _rowKeys[name]?.currentContext;
      final renderObject = target?.findRenderObject();
      if (renderObject != null && _scroll.hasClients) {
        _scroll.position.ensureVisible(renderObject);
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_listFocus.hasPrimaryFocus ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final rows = _rows;
    if (rows.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final index = rows.indexWhere(
      (file) => file.name == ref.read(backupSelectionProvider),
    );
    if (key == LogicalKeyboardKey.escape) {
      _select(null);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        index >= 0) {
      restoreBackupAction(context, ref, rows[index].name);
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final last = rows.length - 1;
    final next = switch (key) {
      LogicalKeyboardKey.arrowDown => ((index < 0 ? -1 : index) + 1).clamp(
        0,
        last,
      ),
      LogicalKeyboardKey.arrowUp =>
        ((index < 0 ? rows.length : index) - 1).clamp(0, last),
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => last,
      _ => null,
    };
    if (next == null) return KeyEventResult.ignored;
    _select(rows[next.toInt()].name);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final user = ref.watch(currentUserProvider).value;
    final backups = ref.watch(backupsProvider);
    final pendingState = ref.watch(pendingRestoreProvider);
    final pending = pendingState.value;
    final busy = ref.watch(backupBusyProvider);
    final selectedName = ref.watch(backupSelectionProvider);
    // ignore: avoid_print
    final formatLocale = ref.watch(effectiveFormatLocaleProvider);
    final integerFormat = NumberFormat.decimalPattern(formatLocale);
    final sizeFormat = NumberFormat.decimalPattern(formatLocale)
      ..minimumFractionDigits = 1
      ..maximumFractionDigits = 1;
    final formatInstant = ref.watch(regionalInstantFormatterProvider);
    final border = (theme.typography.body?.color ?? Colors.black).withValues(
      alpha: 0.12,
    );

    return UiScrollablePage(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiPageHeader(title: t.navBackup, subtitle: t.backupPageHint),
            const SizedBox(height: 18),
            if (busy) ...[
              UiNotice(message: t.backupWorking),
              const SizedBox(height: 8),
            ],
            if (pendingState.hasError) ...[
              UiNotice(
                message: t.loadFailed(errorText(t, pendingState.error!)),
                severity: InfoBarSeverity.error,
              ),
              const SizedBox(height: 8),
            ],
            if (pending != null) ...[
              InfoBar(
                severity: InfoBarSeverity.warning,
                title: Text(t.backupRestorePending(pending)),
                action: Button(
                  onPressed: !busy && hasPermission(user, 'backup.restore')
                      ? () => cancelRestoreAction(context, ref)
                      : null,
                  child: Text(t.backupRestoreCancel),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: Focus(
                focusNode: _listFocus,
                onKeyEvent: _onKey,
                child: UiPanel(
                  expand: true,
                  padding: EdgeInsets.zero,
                  header: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton(
                        key: const ValueKey('backup-create'),
                        onPressed: !busy && hasPermission(user, 'backup.create')
                            ? () => createBackupAction(context, ref)
                            : null,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(FluentIcons.save, size: 14),
                            const SizedBox(width: 6),
                            Text(t.backupNow),
                          ],
                        ),
                      ),
                      Button(
                        onPressed:
                            busy || backups.isLoading || pendingState.isLoading
                            ? null
                            : () => refreshBackups(ref),
                        child: Text(t.actionRefresh),
                      ),
                    ],
                  ),
                  child: backups.when(
                    loading: () => const Center(child: ProgressRing()),
                    error: (error, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: UiNotice(
                        message: t.loadFailed(errorText(t, error)),
                        severity: InfoBarSeverity.error,
                      ),
                    ),
                    data: (list) => list.isEmpty
                        ? UiEmpty(
                            icon: FluentIcons.archive,
                            message: t.backupEmpty,
                          )
                        : ListView.separated(
                            controller: _scroll,
                            itemCount: list.length,
                            separatorBuilder: (_, _) =>
                                Container(height: 1, color: border),
                            itemBuilder: (context, i) {
                              final file = list[i];
                              final selected = file.name == selectedName;
                              return Semantics(
                                selected: selected,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _select(file.name),
                                  child: Container(
                                    key: _rowKeys.putIfAbsent(
                                      file.name,
                                      () => GlobalKey(),
                                    ),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? accent.withValues(alpha: 0.10)
                                          : null,
                                      border: Border(
                                        left: BorderSide(
                                          width: 2,
                                          color: selected
                                              ? accent
                                              : Colors.transparent,
                                        ),
                                      ),
                                    ),
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      10,
                                      16,
                                      10,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                file.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.typography.body
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 3),
                                              Tooltip(
                                                message: file.sizeBytes == 1
                                                    ? t.backupSizeExactBytes(1)
                                                    : t.backupSizeExactBytesFormatted(
                                                        integerFormat.format(
                                                          file.sizeBytes,
                                                        ),
                                                      ),
                                                child: Text(
                                                  '${formatInstant(file.modifiedAt)}'
                                                  '  ·  ${_formatBytes(file.sizeBytes, sizeFormat, integerFormat, t)}',
                                                  style: theme
                                                      .typography
                                                      .caption
                                                      ?.copyWith(
                                                        color: theme
                                                            .typography
                                                            .body
                                                            ?.color
                                                            ?.withValues(
                                                              alpha: 0.6,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Button(
                                          onPressed:
                                              !busy &&
                                                  hasPermission(
                                                    user,
                                                    'backup.restore',
                                                  )
                                              ? () => restoreBackupAction(
                                                  context,
                                                  ref,
                                                  file.name,
                                                )
                                              : null,
                                          child: Text(t.backupRestore),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(
  int bytes,
  NumberFormat format,
  NumberFormat integerFormat,
  AppLocalizations t,
) {
  const kib = 1024;
  const mib = kib * 1024;
  const gib = mib * 1024;
  const tib = gib * 1024;
  if (bytes < kib) {
    return t.backupSizeBytesFormatted(integerFormat.format(bytes));
  }
  if (bytes < mib) return t.backupSizeKib(format.format(bytes / kib));
  if (bytes < gib) return t.backupSizeMib(format.format(bytes / mib));
  if (bytes < tib) return t.backupSizeGib(format.format(bytes / gib));
  return t.backupSizeTib(format.format(bytes / tib));
}
