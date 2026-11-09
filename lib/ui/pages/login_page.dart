import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// 启动门禁：开启登录保护且尚未认证时，先停在这里。
/// 口令只交给 Rust 校验；失败不区分原因，也不回显输入。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _password = TextEditingController();
  final _focus = FocusNode(debugLabel: 'login.password');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = t.loginPasswordRequired);
      _focus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await ref.read(authServiceProvider).signIn(password);
      if (!mounted) return;
      if (ok) {
        _password.clear();
        ref.invalidate(authStatusProvider);
        ref.invalidate(currentUserProvider);
        return;
      }
      _password.clear();
      setState(() {
        _busy = false;
        _error = t.loginWrongPassword;
      });
      _focus.requestFocus();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(AppLocalizations.of(context), error);
      });
    }
  }

  Future<void> _retryDatabase() async {
    try {
      await ref.read(databaseRetrySourceProvider)();
    } catch (_) {
      // 错误由全局提示与状态栏呈现，登录页只负责重试入口。
    }
    if (!mounted) return;
    ref.invalidate(appStatusProvider);
    ref.invalidate(authStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final status = ref.watch(appStatusProvider);
    final ready = status.value?.databaseReady ?? false;
    // 首次读取时不要闪一下“数据库未就绪”的错误条。
    final known = !status.isLoading;
    return ScaffoldPage(
      content: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  FluentIcons.lock,
                  size: 28,
                  color: theme.accentColor.defaultBrushFor(theme.brightness),
                ),
                const SizedBox(height: 12),
                Text(t.appTitle, style: theme.typography.title),
                const SizedBox(height: 6),
                Text(
                  t.loginHint,
                  style: theme.typography.body?.copyWith(
                    color: theme.typography.body?.color?.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 20),
                TextBox(
                  key: const ValueKey('login-password'),
                  controller: _password,
                  focusNode: _focus,
                  autofocus: true,
                  obscureText: true,
                  placeholder: t.loginPassword,
                  enabled: ready && !_busy,
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const ValueKey('login-error'),
                    style: const TextStyle(color: Colors.errorPrimaryColor),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('login-submit'),
                  onPressed: ready && !_busy ? _submit : null,
                  child: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: ProgressRing(strokeWidth: 2),
                        )
                      : Text(t.loginSubmit),
                ),
                if (!ready && known) ...[
                  const SizedBox(height: 16),
                  UiNotice(
                    message: t.loginDatabaseUnavailable,
                    severity: InfoBarSeverity.error,
                  ),
                  const SizedBox(height: 8),
                  Button(
                    key: const ValueKey('login-db-retry'),
                    onPressed: _retryDatabase,
                    child: Text(t.actionRetry),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
