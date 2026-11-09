import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/users/state/user_draft.dart';
import 'package:keel/features/users/state/user_import_provider.dart';
import 'package:keel/ui/pages/user_import_dialog.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/close_guards.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 新建用户工作区：本地 Unicode 校验，提交锁与失败保留输入。
class UsersPage extends ConsumerStatefulWidget {
  const UsersPage({super.key});

  @override
  ConsumerState<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends ConsumerState<UsersPage> {
  static const _id = userWorkspaceEditorId;
  final _nameFocus = FocusNode(debugLabel: 'UsersPage.name');
  final _nameKey = GlobalKey();
  late final TextEditingController _name;
  CloseGuards? _guards;
  String? _validationError;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: ref.read(userDraftProvider(_id)).name);
    _guards = ref.read(closeGuardsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _guards?.register('new-user', () => _canClose());
    });
  }

  @override
  void dispose() {
    _guards?.unregister('new-user');
    _nameFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<bool> _canClose() async {
    if (!mounted) return true;
    return canDiscardUserDraft(context, ref, _id);
  }

  void _reset() {
    _name.clear();
    setState(() => _validationError = null);
    ref.read(userDraftProvider(_id).notifier).state = const UserDraft();
  }

  bool get _active =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  bool get _allowed {
    final identity = ref.read(currentUserProvider);
    return !identity.isLoading &&
        !identity.hasError &&
        hasPermission(identity.asData?.value, 'users.manage');
  }

  bool get _editable {
    if (!mounted ||
        !_active ||
        !_allowed ||
        _confirming ||
        ref.read(userImportOpenProvider)) {
      return false;
    }
    final draft = ref.read(userDraftProvider(_id));
    return !draft.busy && !draft.confirming;
  }

  void _locateName() {
    if (!_editable) return;
    _nameFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_editable || !_nameFocus.hasFocus) return;
      final target = _nameKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.25);
      }
    });
  }

  Future<void> _cancel() async {
    if (!_active || _confirming) return;
    final draft = ref.read(userDraftProvider(_id));
    if (draft.busy || draft.confirming) return;
    setState(() => _confirming = true);
    try {
      if (!await canDiscardUserDraft(context, ref, _id) || !_active) return;
      _reset();
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _save() async {
    if (!_editable) return;
    final t = AppLocalizations.of(context);
    final provider = userDraftProvider(_id);
    final draft = ref.read(provider);
    final error = validateUserName(t, _name.text);
    if (error != null) {
      setState(() => _validationError = error);
      _locateName();
      return;
    }
    setState(() => _validationError = null);
    // Recheck at dispatch; stale toolbar/keyboard callbacks share this gate.
    if (!_editable) return;
    final service = ref.read(userServiceProvider);
    ref.read(provider.notifier).state = draft.copyWith(busy: true);
    try {
      await service.create(normalizeUserName(_name.text), draft.role);
      if (!mounted) return;
      ref.invalidate(usersProvider);
      _reset();
      if (_active) showToast(context, t.userCreated);
    } catch (error) {
      if (!mounted) return;
      ref.read(provider.notifier).state = draft.copyWith(error: error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final provider = userDraftProvider(_id);
    final draft = ref.watch(provider);
    final currentUser = ref.watch(currentUserProvider);
    final allowed =
        !currentUser.isLoading &&
        !currentUser.hasError &&
        hasPermission(currentUser.asData?.value, 'users.manage');
    final locked =
        draft.busy ||
        draft.confirming ||
        _confirming ||
        ref.watch(userImportOpenProvider);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    final labelStyle = theme.typography.body?.copyWith(fontSize: 13);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UiPageHeader(title: t.navNewUser, subtitle: t.usersPageHint),
                const SizedBox(height: 18),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Button(
                    key: const ValueKey('open-user-import'),
                    onPressed: locked || !allowed
                        ? null
                        : () {
                            if (_editable) showUserImportDialog(context);
                          },
                    child: Text(t.userImportTitle),
                  ),
                ),
                const SizedBox(height: 12),
                UiPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (currentUser.hasValue && !allowed) ...[
                        UiNotice(
                          message: t.errPermission,
                          severity: InfoBarSeverity.warning,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_validationError case final validationError?) ...[
                        Semantics(
                          liveRegion: true,
                          child: UiNotice(
                            message:
                                '${t.formErrorSummary}\n'
                                '• ${t.userNameLabel}: $validationError',
                            severity: InfoBarSeverity.error,
                          ),
                        ),
                        Button(
                          onPressed: locked || !allowed ? null : _locateName,
                          child: Text(t.userNameLabel),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(t.userNameLabel, style: labelStyle),
                      const SizedBox(height: 6),
                      TextBox(
                        key: _nameKey,
                        controller: _name,
                        focusNode: _nameFocus,
                        enabled: !locked && allowed,
                        placeholder: t.userNameLabel,
                        onChanged: (name) {
                          if (!_editable) return;
                          ref.read(provider.notifier).state = ref
                              .read(provider)
                              .copyWith(name: name);
                          if (_validationError != null) {
                            setState(
                              () =>
                                  _validationError = validateUserName(t, name),
                            );
                          }
                        },
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: 16),
                      Text(t.userRoleLabel, style: labelStyle),
                      const SizedBox(height: 6),
                      ComboBox<String>(
                        value: draft.role,
                        isExpanded: true,
                        items: [
                          for (final (role, label) in [
                            ('admin', t.roleAdmin),
                            ('operator', t.roleOperator),
                            ('viewer', t.roleViewer),
                          ])
                            ComboBoxItem(value: role, child: Text(label)),
                        ],
                        onChanged: locked || !allowed
                            ? null
                            : (role) {
                                if (_editable && role != null) {
                                  ref.read(provider.notifier).state = ref
                                      .read(provider)
                                      .copyWith(role: role);
                                }
                              },
                      ),
                      if (draft.error case final error?) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: UiNotice(
                            message: errorText(t, error),
                            severity: InfoBarSeverity.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        'Ctrl+S',
                        style: theme.typography.caption?.copyWith(color: muted),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Button(
                            onPressed: locked ? null : _cancel,
                            child: Text(t.actionCancel),
                          ),
                          FilledButton(
                            onPressed: locked || !allowed ? null : _save,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (draft.busy) ...[
                                  const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: ProgressRing(strokeWidth: 2),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  draft.busy ? t.userCreating : t.userCreate,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
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
