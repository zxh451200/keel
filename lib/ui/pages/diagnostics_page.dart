import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/diagnostic_export_actions.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/diagnostics.dart';
import 'package:keel/ui/pages/diagnostics/diagnostic_history_dialog.dart';
import 'package:keel/ui/pages/diagnostics/external_diagnostic_dialog.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 诊断中心：最近错误、警告和诊断事件；内容在 Rust 侧已脱敏。
class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  late final TextEditingController _search;
  final _searchFocus = FocusNode(debugLabel: 'Diagnostics.search');
  bool _invalidId = false;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: ref.read(diagnosticsFilterProvider).correlationId,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _interactive =>
      mounted &&
      ModalRoute.of(context)?.isCurrent != false &&
      TickerMode.valuesOf(context).enabled;

  void _setFilter(DiagnosticsFilter next) {
    final current = ref.read(diagnosticsFilterProvider);
    if (current.minLevel == next.minLevel &&
        current.correlationId == next.correlationId) {
      refreshDiagnostics(ref);
    } else {
      ref.read(diagnosticsFilterProvider.notifier).state = next;
    }
  }

  void _submitSearch() {
    if (!_interactive) return;
    final id = normalizeDiagnosticId(_search.text);
    setState(() => _invalidId = !validDiagnosticId(id));
    if (_invalidId) {
      _searchFocus.requestFocus();
      return;
    }
    _search.text = id;
    _setFilter(
      DiagnosticsFilter(
        minLevel: ref.read(diagnosticsFilterProvider).minLevel,
        correlationId: id,
      ),
    );
  }

  void _reset() {
    if (!_interactive) return;
    _search.clear();
    setState(() => _invalidId = false);
    _setFilter(const DiagnosticsFilter());
    _searchFocus.requestFocus();
  }

  void _focusSearch() {
    if (!_interactive) return;
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  void _refresh() {
    if (_interactive) refreshDiagnostics(ref);
  }

  Future<void> _exportFlow() async {
    if (!_interactive) return;
    await exportDiagnosticPackAction(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final filter = ref.watch(diagnosticsFilterProvider);
    final events = ref.watch(diagnosticsEventsProvider);
    final user = ref.watch(currentUserProvider);
    final formatInstant = ref.watch(regionalInstantFormatterProvider);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    final canExport =
        hasPermission(user.value, 'diagnostics.export') &&
        !ref.watch(diagnosticExportOpenProvider) &&
        !ref.watch(diagnosticPackBusyProvider);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.f5): _refresh,
      },
      child: Focus(
        autofocus: true,
        child: UiScrollablePage(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UiPageHeader(title: t.navDiagnostics, subtitle: t.diagPageHint),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 260,
                      child: TextBox(
                        controller: _search,
                        focusNode: _searchFocus,
                        placeholder: t.diagSearchIdHint,
                        prefix: const Padding(
                          padding: EdgeInsetsDirectional.only(start: 8),
                          child: Icon(FluentIcons.search, size: 12),
                        ),
                        onChanged: (_) {
                          if (_invalidId) setState(() => _invalidId = false);
                        },
                        onSubmitted: (_) => _submitSearch(),
                      ),
                    ),
                    FilledButton(
                      onPressed: _submitSearch,
                      child: Text(t.actionSearch),
                    ),
                    Button(onPressed: _reset, child: Text(t.actionReset)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t.diagMinLevel,
                          style: theme.typography.caption?.copyWith(
                            color: muted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 120,
                          child: ComboBox<String>(
                            value: filter.minLevel,
                            isExpanded: true,
                            items: [
                              for (final value in const [
                                'info',
                                'warn',
                                'error',
                              ])
                                ComboBoxItem(
                                  value: value,
                                  child: Text(_levelLabel(t, value)),
                                ),
                            ],
                            onChanged: (value) {
                              if (_interactive && value != null) {
                                _setFilter(
                                  DiagnosticsFilter(
                                    minLevel: value,
                                    correlationId: ref
                                        .read(diagnosticsFilterProvider)
                                        .correlationId,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 4),
                    Button(
                      onPressed: canExport ? _exportFlow : null,
                      child: Text(t.diagExport),
                    ),
                    Button(
                      onPressed: canExport
                          ? () => showExternalDiagnosticDialog(context, ref)
                          : null,
                      child: Text(t.externalDiagnosticTitle),
                    ),
                    Button(
                      onPressed:
                          !user.isLoading &&
                              !user.hasError &&
                              hasPermission(
                                user.asData?.value,
                                'diagnostics.export',
                              )
                          ? () {
                              if (!_interactive ||
                                  ref.read(currentUserProvider).isLoading ||
                                  !hasPermission(
                                    ref.read(currentUserProvider).asData?.value,
                                    'diagnostics.export',
                                  )) {
                                return;
                              }
                              showDialog<void>(
                                context: context,
                                builder: (_) => const DiagnosticHistoryDialog(),
                              );
                            }
                          : null,
                      child: Text(t.diagHistoryTitle),
                    ),
                    Button(
                      onPressed: events.isLoading ? null : _refresh,
                      child: Text(t.actionRefresh),
                    ),
                  ],
                ),
                if (_invalidId)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      t.diagSearchIdInvalid,
                      style: theme.typography.caption?.copyWith(
                        color: const Color(0xFFC42B1C),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: UiPanel(
                    expand: true,
                    padding: EdgeInsets.zero,
                    footer: Row(
                      children: [
                        Icon(FluentIcons.info, size: 12, color: muted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Tooltip(
                            message: t.diagSearchScope,
                            child: Text(
                              t.diagSearchScope,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.typography.caption?.copyWith(
                                color: muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    child: events.when(
                      skipLoadingOnRefresh: false,
                      skipLoadingOnReload: false,
                      loading: () => const Center(child: ProgressRing()),
                      error: (error, _) => Center(
                        child: Text(t.loadFailed(errorText(t, error))),
                      ),
                      data: (list) => list.isEmpty
                          ? UiEmpty(
                              icon: FluentIcons.health,
                              message:
                                  filter.correlationId.isNotEmpty ||
                                      filter.minLevel != 'info'
                                  ? t.diagNoMatches
                                  : t.diagEmpty,
                            )
                          : ListView.separated(
                              key: ObjectKey(list),
                              itemCount: list.length,
                              separatorBuilder: (_, _) => Container(
                                height: 1,
                                color:
                                    (theme.typography.body?.color ??
                                            Colors.black)
                                        .withValues(alpha: 0.07),
                              ),
                              itemBuilder: (context, i) => _EventRow(
                                event: list[i],
                                formatInstant: formatInstant,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _levelLabel(AppLocalizations t, String level) => switch (level) {
  'error' => t.levelError,
  'warn' => t.levelWarn,
  _ => t.levelInfo,
};

class _EventRow extends StatefulWidget {
  const _EventRow({required this.event, required this.formatInstant});

  final DiagnosticEvent event;
  final InstantFormatter formatInstant;

  @override
  State<_EventRow> createState() => _EventRowState();
}

class _EventRowState extends State<_EventRow> {
  bool _copying = false;

  bool get _canNotify =>
      mounted &&
      ModalRoute.of(context)?.isCurrent != false &&
      TickerMode.valuesOf(context).enabled;

  Future<void> _copyId() async {
    if (!mounted ||
        _copying ||
        widget.event.correlationId.isEmpty ||
        !_canNotify) {
      return;
    }
    final t = AppLocalizations.of(context);
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: widget.event.correlationId));
      if (!_canNotify || !mounted) return;
      showToast(context, t.diagIdCopied);
    } catch (error) {
      if (!_canNotify || !mounted) return;
      showToast(context, errorText(t, error), severity: InfoBarSeverity.error);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final event = widget.event;
    final muted = theme.typography.body?.color?.withValues(alpha: 0.6);
    final head = [
      widget.formatInstant(event.at),
      _levelLabel(t, event.level),
      event.area,
      if (event.code.isNotEmpty) event.code,
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.summary,
                  style: theme.typography.body?.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  event.correlationId.isEmpty
                      ? head
                      : '$head  ·  ${event.correlationId}',
                  style: theme.typography.caption?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          if (event.correlationId.isNotEmpty)
            Tooltip(
              message: t.diagCopyId,
              child: IconButton(
                onPressed: _copying ? null : _copyId,
                icon: const Icon(FluentIcons.copy, size: 12),
              ),
            ),
        ],
      ),
    );
  }
}
