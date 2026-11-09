import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 登录保护设置：开关 + 口令（只保存 Argon2id 校验值）。
/// 只有管理员可以修改；开启状态下关闭必须提供当前口令。
class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key});

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 按钮可用性随输入实时更新（校验仍在提交时再做一次）。
    for (final controller in [_current, _next, _confirm]) {
      controller.addListener(_onInputChanged);
    }
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in [_current, _next, _confirm]) {
      controller.removeListener(_onInputChanged);
      controller.dispose();
    }
    super.dispose();
  }

  void _clearPasswords() {
    _current.clear();
    _next.clear();
    _confirm.clear();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      _clearPasswords();
      ref.invalidate(authStatusProvider);
      showToast(context, AppLocalizations.of(context).securitySaved);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = errorText(AppLocalizations.of(context), error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validateNew(AppLocalizations t) {
    if (_next.text.runes.length < 8) return t.securityTooShort;
    if (_next.text != _confirm.text) return t.securityMismatch;
    return null;
  }

  Future<void> _savePassword() async {
    final t = AppLocalizations.of(context);
    final invalid = _validateNew(t);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final current = _current.text.isEmpty ? null : _current.text;
    await _run(
      () => ref.read(authServiceProvider).savePassword(current, _next.text),
    );
  }

  Future<void> _toggle(bool hasPassword, bool enabled) async {
    final t = AppLocalizations.of(context);
    // 已有口令时开关用“当前口令”；首次开启用新口令（同时设置）。
    final password = hasPassword ? _current.text : _next.text;
    if (password.isEmpty) {
      setState(() => _error = t.loginPasswordRequired);
      return;
    }
    if (!hasPassword && !enabled) {
      final invalid = _validateNew(t);
      if (invalid != null) {
        setState(() => _error = invalid);
        return;
      }
    }
    await _run(
      () => ref.read(authServiceProvider).setRequired(!enabled, password),
    );
  }

  Future<void> _lockNow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await lockAppNow(ref);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = errorText(AppLocalizations.of(context), error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final user = ref.watch(currentUserProvider);
    final status = ref.watch(authStatusProvider);
    final value = status.value;
    final canManage =
        hasPermission(user.value, 'users.manage') &&
        !user.isLoading &&
        !user.hasError;
    final hasPassword = value?.hasPassword ?? false;
    final enabled = value?.loginRequired ?? false;
    final canSave =
        canManage &&
        !_busy &&
        (!hasPassword || _current.text.isNotEmpty) &&
        _next.text.runes.length >= 8 &&
        _next.text == _confirm.text;
    final canToggle =
        canManage &&
        !_busy &&
        (hasPassword ? _current.text.isNotEmpty : canSave);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.7);

    return UiScrollablePage(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UiPageHeader(title: t.navSecurity, subtitle: t.securityHint),
            const SizedBox(height: 16),
            if (!canManage && user.hasValue)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: UiNotice(message: t.securityAdminOnly),
              ),
            Expanded(
              child: UiPanel(
                expand: true,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Icon(
                          enabled ? FluentIcons.lock : FluentIcons.unlock,
                          size: 16,
                          color: enabled ? const Color(0xFF107C10) : muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            enabled ? t.securityStatusOn : t.securityStatusOff,
                            key: const ValueKey('security-status'),
                            style: theme.typography.bodyStrong,
                          ),
                        ),
                      ],
                    ),
                    if (!hasPassword)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          t.securityNoPassword,
                          style: theme.typography.caption?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 420,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasPassword) ...[
                            Text(t.securityCurrent),
                            const SizedBox(height: 4),
                            TextBox(
                              key: const ValueKey('security-current'),
                              controller: _current,
                              obscureText: true,
                              enabled: canManage && !_busy,
                            ),
                            const SizedBox(height: 12),
                          ],
                          Text(t.securityNew),
                          const SizedBox(height: 4),
                          TextBox(
                            key: const ValueKey('security-new'),
                            controller: _next,
                            obscureText: true,
                            enabled: canManage && !_busy,
                          ),
                          const SizedBox(height: 12),
                          Text(t.securityConfirm),
                          const SizedBox(height: 4),
                          TextBox(
                            key: const ValueKey('security-confirm'),
                            controller: _confirm,
                            obscureText: true,
                            enabled: canManage && !_busy,
                            onSubmitted: (_) => _savePassword(),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t.securityPasswordRule,
                            style: theme.typography.caption?.copyWith(
                              color: muted,
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              key: const ValueKey('security-error'),
                              style: const TextStyle(
                                color: Colors.errorPrimaryColor,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Button(
                                key: const ValueKey('security-save'),
                                onPressed: canSave ? _savePassword : null,
                                child: Text(t.securitySavePassword),
                              ),
                              FilledButton(
                                key: const ValueKey('security-toggle'),
                                onPressed: canToggle
                                    ? () => _toggle(hasPassword, enabled)
                                    : null,
                                child: Text(
                                  enabled
                                      ? t.securityDisable
                                      : t.securityEnable,
                                ),
                              ),
                              if (enabled)
                                Button(
                                  key: const ValueKey('security-lock'),
                                  onPressed: _busy ? null : _lockNow,
                                  child: Text(t.securityLockNow),
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
          ],
        ),
      ),
    );
  }
}

/// 供页面按钮与外壳命令共用：清除当前用户并回到登录页。
Future<void> lockAppNow(WidgetRef ref) async {
  await ref.read(authServiceProvider).lock();
  ref.invalidate(authStatusProvider);
  ref.invalidate(currentUserProvider);
}

final securityLockEnabledProvider = Provider<bool>(
  (ref) => ref.watch(authStatusProvider).value?.loginRequired ?? false,
);

/// 外壳命令：仅在开启登录保护后可用。
List<UiCommand> securityShellCommands() => [
  UiCommand(
    id: 'security.lock',
    label: (t) => t.securityLockNow,
    icon: FluentIcons.lock,
    isEnabledProvider: securityLockEnabledProvider,
    onInvoke: (context, ref) => lockAppNow(ref),
  ),
];
