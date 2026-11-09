import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/features/settings_import/settings_import_shell_commands.dart';
import 'package:keel/features/settings_import/state/settings_import_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/settings.dart' show ExternalConfigPreview;
import 'package:keel/ui/widgets/ui_layout.dart';

const maxSettingsImportBytes = 1024 * 1024;

/// 用户主动粘贴受限 JSON；Rust 负责脱敏预览与确认写入。
class SettingsImportPage extends ConsumerStatefulWidget {
  const SettingsImportPage({super.key});

  @override
  ConsumerState<SettingsImportPage> createState() => _SettingsImportPageState();
}

class _SettingsImportPageState extends ConsumerState<SettingsImportPage> {
  final _input = TextEditingController();
  ExternalConfigPreview? _preview;
  (String, String)? _previewOwner;
  Object? _error;
  bool _tooLarge = false;
  bool _inputRejected = false;
  bool _done = false;
  int _revision = 0;
  int _bytes = 0;

  late final SettingsImportPageActions _actions = SettingsImportPageActions(
    openFile: _selectFile,
    cancel: _cancel,
    reload: _reload,
  );
  SettingsImportActionsRegistry? _actionsRegistry;

  bool get _active =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool get _allowed => hasPermission(
    ref.read(currentUserProvider).asData?.value,
    'settings.import',
  );

  (String, String)? get _owner {
    final user = ref.read(currentUserProvider).asData?.value;
    return user == null ? null : (user.name, user.role);
  }

  @override
  void initState() {
    super.initState();
    _actionsRegistry = ref.read(settingsImportActionsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _actionsRegistry?.register(_actions);
    });
  }

  @override
  void dispose() {
    _actionsRegistry?.unregister(_actions);
    _input.dispose();
    super.dispose();
  }

  void _changed(String value) {
    if (!_active || ref.read(preferencesImportGateProvider).blocksWrites) {
      return;
    }
    setState(() {
      _revision++;
      _bytes = value.isEmpty ? 0 : utf8.encode(value).length;
      _preview = null;
      _previewOwner = null;
      _error = null;
      _tooLarge = false;
      _inputRejected = false;
      _done = false;
    });
  }

  void _cancel() {
    if (!_active || ref.read(preferencesImportGateProvider).blocksWrites) {
      return;
    }
    setState(() {
      _revision++;
      _input.clear();
      _bytes = 0;
      _preview = null;
      _previewOwner = null;
      _error = null;
      _tooLarge = false;
      _inputRejected = false;
      _done = false;
    });
  }

  TextEditingValue _limitInput(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length <= maxSettingsImportBytes) return newValue;
    setState(() {
      _inputRejected = true;
      _tooLarge = true;
      _preview = null;
      _done = false;
    });
    return oldValue;
  }

  Future<void> _prepare() async {
    if (!_active ||
        !_allowed ||
        _inputRejected ||
        !ref.read(settingsWritableProvider) ||
        !ref.read(workspaceNavigationWritableProvider)) {
      return;
    }
    final gate = ref.read(preferencesImportGateProvider.notifier);
    if (!gate.begin()) return;
    final service = ref.read(settingsImportServiceProvider);
    final revision = _revision;
    final owner = _owner;
    setState(() {
      _preview = null;
      _error = null;
      _tooLarge = false;
      _done = false;
    });
    try {
      if (_input.text.isEmpty || _input.text.length > maxSettingsImportBytes) {
        setState(() => _tooLarge = true);
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(_input.text));
      if (bytes.length > maxSettingsImportBytes) {
        setState(() => _tooLarge = true);
        return;
      }
      final preview = await service.prepare(bytes);
      if (_active && revision == _revision && owner == _owner && _allowed) {
        setState(() {
          _preview = preview;
          _previewOwner = owner;
          _input.clear();
          _bytes = 0;
        });
      }
    } catch (error) {
      if (_active && owner == _owner) setState(() => _error = error);
    } finally {
      gate.finish();
    }
  }

  Future<void> _selectFile() async {
    if (!_active ||
        !_allowed ||
        !ref.read(settingsWritableProvider) ||
        !ref.read(workspaceNavigationWritableProvider)) {
      return;
    }
    final gate = ref.read(preferencesImportGateProvider.notifier);
    if (!gate.begin()) return;
    final picker = ref.read(settingsConfigFilePickerProvider);
    final prepare = ref.read(settingsFilePrepareProvider);
    final owner = _owner;
    final revision = ++_revision;
    final t = AppLocalizations.of(context);
    setState(() {
      _preview = null;
      _previewOwner = null;
      _error = null;
      _done = false;
    });
    try {
      final path = await picker(
        t.settingsImportChooseFile,
        t.settingsImportJsonFilter,
        t.actionCancel,
        t.actionOpen,
      );
      if (path == null ||
          !_active ||
          owner != _owner ||
          !_allowed ||
          revision != _revision ||
          !ref.read(settingsWritableProvider) ||
          !ref.read(workspaceNavigationWritableProvider)) {
        return;
      }
      final preview = await prepare(path);
      if (_active && owner == _owner && _allowed && revision == _revision) {
        setState(() {
          _input.clear();
          _bytes = 0;
          _inputRejected = false;
          _tooLarge = false;
          _preview = preview;
          _previewOwner = owner;
        });
      }
    } catch (error) {
      if (_active && owner == _owner) setState(() => _error = error);
    } finally {
      gate.finish();
    }
  }

  Future<void> _confirm(ExternalConfigPreview preview) async {
    if (!_active ||
        !_allowed ||
        !identical(_preview, preview) ||
        _previewOwner != _owner ||
        !ref.read(settingsWritableProvider) ||
        !ref.read(workspaceNavigationWritableProvider) ||
        ref.read(preferencesImportGateProvider).blocksWrites) {
      return;
    }
    setState(() {
      _preview = null;
      _error = null;
      _done = false;
    });
    try {
      await commitSettingsImport(ref, preview.previewId);
      if (_active) setState(() => _done = true);
    } catch (error) {
      if (_active) setState(() => _error = error);
    }
  }

  Future<void> _reload() async {
    if (!_active) return;
    final gate = ref.read(preferencesImportGateProvider);
    if (gate.busy || !gate.reloadRequired) return;
    setState(() => _error = null);
    try {
      await reloadImportedPreferences(ref);
      if (_active) setState(() => _done = true);
    } catch (error) {
      if (_active) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final gate = ref.watch(preferencesImportGateProvider);
    final user = ref.watch(currentUserProvider);
    final allowed = hasPermission(user.asData?.value, 'settings.import');
    final writable =
        ref.watch(settingsWritableProvider) &&
        ref.watch(workspaceNavigationWritableProvider);
    final preview = _previewOwner == _owner ? _preview : null;
    final overLimit = _bytes > maxSettingsImportBytes;
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    final sizeLabel = t.settingsImportSizeCounter(
      NumberFormat.decimalPattern(ref.watch(effectiveFormatLocaleProvider))
          .format(_bytes),
    );

    final notices = <Widget>[
      if (gate.busy)
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: ProgressRing(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(t.settingsImportWorking),
          ],
        ),
      if (!allowed)
        UiNotice(message: t.errPermission, severity: InfoBarSeverity.warning),
      if (!writable)
        UiNotice(
          message: t.settingsProtected,
          severity: InfoBarSeverity.warning,
        ),
      if (_error case final error?)
        UiNotice(message: errorText(t, error), severity: InfoBarSeverity.error),
      if (gate.reloadRequired)
        InfoBar(
          title: Text(t.settingsImportReloadHint),
          severity: InfoBarSeverity.error,
          action: Button(
            onPressed: gate.busy ? null : () => unawaited(_reload()),
            child: Text(t.actionRetry),
          ),
        ),
      if (_done && !gate.reloadRequired)
        UiNotice(message: t.settingsImportDone),
    ];

    final inputBody = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextBox(
            controller: _input,
            enabled: allowed && writable && !gate.blocksWrites,
            minLines: 12,
            maxLines: 18,
            autocorrect: false,
            enableSuggestions: false,
            style: _monoStyle(color: theme.typography.body?.color),
            placeholder: _sampleConfig,
            inputFormatters: [TextInputFormatter.withFunction(_limitInput)],
            onChanged: _changed,
          ),
          if (_tooLarge)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t.settingsImportLimit,
                style: theme.typography.caption?.copyWith(
                  color: const Color(0xFFC42B1C),
                ),
              ),
            ),
        ],
      ),
    );

    final inputPanel = UiPanel(
      padding: EdgeInsets.zero,
      header: Row(
        children: [
          Icon(FluentIcons.code, size: 14, color: muted),
          const SizedBox(width: 8),
          Expanded(child: Text(t.settingsImportInput)),
          Text(
            sizeLabel,
            style: theme.typography.caption?.copyWith(
              color: overLimit ? const Color(0xFFC42B1C) : muted,
            ),
          ),
        ],
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          Button(
            onPressed: !allowed || !writable || gate.blocksWrites
                ? null
                : () => unawaited(_selectFile()),
            child: Text(t.settingsImportChooseFile),
          ),
          Button(
            onPressed: gate.blocksWrites ? null : _cancel,
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed:
                !allowed || !writable || gate.blocksWrites || _inputRejected
                ? null
                : () => unawaited(_prepare()),
            child: Text(t.diagPackPreview),
          ),
        ],
      ),
      child: inputBody,
    );

    final previewBody = Padding(
      padding: const EdgeInsets.all(16),
      child: preview == null
          ? SizedBox(
              height: 230,
              child: UiEmpty(
                icon: FluentIcons.document,
                message: t.settingsImportPreviewEmpty,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetaChip(
                      label: t.settingsImportSnapshotVersion(
                        '${preview.configVersion}',
                      ),
                    ),
                    if (preview.sensitiveCategories.isNotEmpty)
                      _MetaChip(
                        label: t.settingsImportRedactedCount(
                          '${preview.sensitiveCategories.length}',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (theme.typography.body?.color ?? Colors.black)
                          .withValues(alpha: 0.10),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      preview.preview,
                      style: _monoStyle(color: theme.typography.body?.color),
                    ),
                  ),
                ),
              ],
            ),
    );

    final previewPanel = UiPanel(
      padding: EdgeInsets.zero,
      header: Row(
        children: [
          Icon(FluentIcons.shield, size: 14, color: muted),
          const SizedBox(width: 8),
          Expanded(child: Text(t.settingsImportPreviewTitle)),
        ],
      ),
      footer: preview == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t.settingsImportPreviewHint,
                  style: theme.typography.caption?.copyWith(
                    color: muted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    onPressed: !allowed || !writable || gate.blocksWrites
                        ? null
                        : () => unawaited(_confirm(preview)),
                    child: Text(t.settingsImportConfirm),
                  ),
                ),
              ],
            ),
      child: previewBody,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UiPageHeader(
            title: t.navSettingsImport,
            subtitle: t.settingsImportInputHint,
          ),
          const SizedBox(height: 14),
          if (notices.isNotEmpty) ...[
            for (final notice in notices)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: notice),
            const SizedBox(height: 6),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 880) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: inputPanel),
                    const SizedBox(width: 20),
                    Expanded(flex: 5, child: previewPanel),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  inputPanel,
                  const SizedBox(height: 16),
                  previewPanel,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

const _sampleConfig =
    '{\n'
    '  "language": "zh",\n'
    '  "theme": "dark",\n'
    '  "format_locale": "zh_CN"\n'
    '}';

TextStyle _monoStyle({Color? color}) => TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: const [
    'Cascadia Mono',
    'Menlo',
    'DejaVu Sans Mono',
    'Noto Sans Mono',
    'monospace',
  ],
  fontSize: 12.5,
  height: 1.55,
  color: color,
);

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (theme.typography.body?.color ?? Colors.black).withValues(
            alpha: 0.12,
          ),
        ),
      ),
      child: Text(
        label,
        style: theme.typography.caption?.copyWith(
          color: theme.typography.body?.color?.withValues(alpha: 0.62),
        ),
      ),
    );
  }
}
