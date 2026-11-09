import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/locale_provider.dart';
import 'package:keel/features/audit/ui/audit_shell_commands.dart';
import 'package:keel/features/backup/backup_shell_commands.dart';
import 'package:keel/features/diagnostics/diagnostics_shell_commands.dart';
import 'package:keel/features/settings_import/settings_import_shell_commands.dart';
import 'package:keel/features/tasks/tasks_shell_commands.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/core/state/theme_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/pages/audit_page.dart';
import 'package:keel/ui/pages/backup_page.dart';
import 'package:keel/ui/pages/customers_page.dart';
import 'package:keel/ui/pages/diagnostics_page.dart';
import 'package:keel/ui/pages/form_samples_page.dart';
import 'package:keel/ui/pages/login_page.dart';
import 'package:keel/ui/pages/samples_page.dart';
import 'package:keel/ui/pages/security_page.dart';
import 'package:keel/ui/pages/settings_import_page.dart';
import 'package:keel/ui/pages/tasks_page.dart';
import 'package:keel/ui/pages/users_page.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/theme.dart';
import 'package:keel/ui/ui_page.dart';

/// Fluent 重构中的新应用根节点。
class KeelApp extends ConsumerWidget {
  const KeelApp({super.key, this.locale});

  final Locale? locale;

  static final List<UiPage> _pages = [
    UiPage(
      kind: 'audit',
      title: (t) => t.navAudit,
      icon: FluentIcons.list,
      builder: (_, _) => const AuditPage(),
      commands: auditShellCommands(),
    ),
    UiPage(
      kind: 'diagnostics',
      title: (t) => t.navDiagnostics,
      icon: FluentIcons.health,
      builder: (_, _) => const DiagnosticsPage(),
      commands: diagnosticsShellCommands(),
    ),
    UiPage(
      kind: 'backup',
      title: (t) => t.navBackup,
      icon: FluentIcons.cloud,
      builder: (_, _) => const BackupPage(),
      commands: backupShellCommands(),
    ),
    UiPage(
      kind: 'customers',
      title: (t) => t.navCustomers,
      icon: FluentIcons.people,
      builder: (_, _) => const CustomersPage(),
      commands: customerShellCommands(),
    ),
    UiPage(
      kind: 'new-user',
      title: (t) => t.navNewUser,
      icon: FluentIcons.contact,
      builder: (_, _) => const UsersPage(),
    ),
    UiPage(
      kind: 'security',
      title: (t) => t.navSecurity,
      icon: FluentIcons.lock,
      builder: (_, _) => const SecurityPage(),
      commands: securityShellCommands(),
    ),
    UiPage(
      kind: 'settings-import',
      title: (t) => t.navSettingsImport,
      icon: FluentIcons.settings,
      builder: (_, _) => const SettingsImportPage(),
      commands: settingsImportShellCommands(),
    ),
    UiPage(
      kind: 'tasks',
      title: (t) => t.navTasks,
      icon: FluentIcons.task_manager,
      builder: (_, _) => const TasksPage(),
      commands: tasksShellCommands(),
    ),
    UiPage(
      kind: 'samples',
      title: (t) => t.samplesTitle,
      navTitle: (t) => t.samplesNavLabel,
      icon: FluentIcons.code,
      builder: (_, _) => const SamplesPage(),
    ),
    UiPage(
      kind: 'form_samples',
      title: (t) => t.formSamplesTitle,
      navTitle: (t) => t.formSamplesNavLabel,
      icon: FluentIcons.edit,
      builder: (_, _) => const FormSamplesHost(),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    // 登录门禁：数据库就绪后读取一次；锁定期间只渲染登录页，不构建外壳。
    final auth = ref.watch(authStatusProvider);
    final locked = auth.value?.locked ?? false;
    return FluentApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      locale: locale ?? ref.watch(localeProvider),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FluentLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: keelFluentTheme(Brightness.light),
      darkTheme: keelFluentTheme(Brightness.dark),
      themeMode: switch (mode) {
        KeelThemeMode.light => ThemeMode.light,
        KeelThemeMode.dark => ThemeMode.dark,
        KeelThemeMode.system => ThemeMode.system,
      },
      home: auth.isLoading
          ? const _StartupSplash()
          : locked
          ? const LoginPage()
          : KeelShell(pages: _pages),
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) => const Center(child: ProgressRing());
}
