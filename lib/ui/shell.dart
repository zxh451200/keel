import 'dart:ui' show AppExitResponse;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/current_activities_provider.dart';
import 'package:keel/ui/widgets/current_activities.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/core/state/format_locale_provider.dart';
import 'package:keel/core/state/regional_settings_provider.dart';
import 'package:keel/features/users/state/user_import_provider.dart';
import 'package:keel/core/state/locale_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/state/theme_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/features/audit/state/audit_print_provider.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/close_guards.dart';
import 'package:keel/ui/pages/dashboard_page.dart';
import 'package:keel/ui/tokens.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

/// Fluent 桌面外壳：菜单栏 + 命令栏 + 模块侧栏 + 标签工作区 + 状态栏。
class KeelShell extends ConsumerStatefulWidget {
  const KeelShell({super.key, required this.pages});

  final List<UiPage> pages;

  @override
  ConsumerState<KeelShell> createState() => _KeelShellState();
}

class _KeelShellState extends ConsumerState<KeelShell> {
  final _open = <String>['dashboard'];
  String _active = 'dashboard';
  final _tabKeys = <String, GlobalKey>{};
  // 页面内容用 GlobalKey：Flutter 3.47 的 IndexedStack 用无键 _VisibilityScope
  // 包裹子项，列表收缩时按键匹配退化为按位置更新，普通 ValueKey 会把隐藏页
  // 销毁重建；GlobalKey 让元素在框架内重定位，保留其他页面的状态。
  final _pageKeys = <String, GlobalKey>{};
  late final AppLifecycleListener _lifecycle;
  bool _closing = false;
  int _tabsRevision = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant KeelShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.pages, widget.pages)) _tabsRevision++;
  }

  bool _kindBusy(String kind) => switch (kind) {
    'new-user' => ref.read(userImportOpenProvider),
    'backup' => ref.read(backupBusyProvider),
    'diagnostics' => ref.read(diagnosticPackBusyProvider),
    'settings-import' => ref.read(preferencesImportGateProvider).blocksWrites,
    'tasks' || 'audit' =>
      ref.read(auditExportProvider).busy || ref.read(auditPrintBusyProvider),
    _ => false,
  };

  bool get _exitBusy =>
      ref.read(userImportOpenProvider) ||
      ref.read(auditExportProvider).busy ||
      ref.read(auditPrintBusyProvider) ||
      ref.read(backupBusyProvider) ||
      ref.read(diagnosticPackBusyProvider) ||
      ref.read(preferencesImportGateProvider).busy ||
      ref.read(settingsSaveProvider).saving ||
      ref.read(databaseRecoveryProvider).retrying;

  /// 关闭标签与系统退出共用同一组条件；任何页面拒绝就取消退出。
  Future<bool> _canCloseKind(String kind) async {
    if (_kindBusy(kind)) return false;
    final guard = ref.read(closeGuardsProvider)[kind];
    if (guard == null && (kind == 'new-user' || kind == 'form_samples')) {
      return false;
    }
    if (guard != null) {
      try {
        if (!await guard()) return false;
      } catch (_) {
        return false;
      }
    }
    return mounted &&
        identical(ref.read(closeGuardsProvider)[kind], guard) &&
        !_kindBusy(kind);
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (_closing || _exitBusy) return AppExitResponse.cancel;
    final revision = _tabsRevision;
    final snapshot = List<String>.of(_open);
    final active = _active;
    final guards = ref.read(closeGuardsProvider);
    setState(() => _closing = true);
    try {
      for (final kind in snapshot) {
        if (!await _canCloseKind(kind)) return AppExitResponse.cancel;
        if (!mounted ||
            revision != _tabsRevision ||
            active != _active ||
            !listEquals(snapshot, _open) ||
            !identical(guards, ref.read(closeGuardsProvider)) ||
            _exitBusy) {
          return AppExitResponse.cancel;
        }
      }
      return !_exitBusy ? AppExitResponse.exit : AppExitResponse.cancel;
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  void _openPage(String kind) {
    if (!mounted || _closing) return;
    if (kind != 'dashboard' && !widget.pages.any((page) => page.kind == kind)) {
      return;
    }
    if (_active != kind || !_open.contains(kind)) _tabsRevision++;
    if (!_open.contains(kind)) {
      setState(() => _open.add(kind));
    }
    setState(() => _active = kind);
    _revealActiveTab();
    // 最近访问只记“显式打开/切换”，关闭自动选页不记。
    ref.read(workspaceNavigationPreferencesProvider.notifier).recordVisit(kind);
  }

  bool _activitiesOpen = false;

  Set<String> get _activityPages => {
    'dashboard',
    for (final page in widget.pages) page.kind,
  };

  void _locateActivity(CurrentActivity activity) {
    if (!mounted ||
        _closing ||
        _activitiesOpen ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final kind = currentActivityDestination(
      activity,
      current: ref.read(currentActivitiesProvider),
      registeredPages: _activityPages,
    );
    if (kind != null) _openPage(kind);
  }

  Future<void> _showCurrentActivities() async {
    if (!mounted ||
        _closing ||
        _activitiesOpen ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _activitiesOpen = true;
    final revision = _tabsRevision;
    ModalRoute<CurrentActivity>? detailRoute;
    CurrentActivity? selected;
    try {
      selected = await showDialog<CurrentActivity>(
        context: context,
        builder: (dialogContext) {
          detailRoute = ModalRoute.of<CurrentActivity>(dialogContext);
          final t = AppLocalizations.of(dialogContext);
          return ContentDialog(
            title: Text(t.navTasks),
            content: SingleChildScrollView(
              child: CurrentActivities(
                registeredPages: _activityPages,
                onLocate: (activity) =>
                    Navigator.of(dialogContext).pop(activity),
              ),
            ),
            actions: [
              Button(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(t.actionClose),
              ),
            ],
          );
        },
      );
      // Wait for the modal transition and overlay removal before navigation.
      await detailRoute?.completed;
    } finally {
      _activitiesOpen = false;
    }
    if (mounted && revision == _tabsRevision && selected != null) {
      _locateActivity(selected);
    }
  }

  /// 当前标签可能因横向滚动在视野外，切换后把它滚进来。
  void _revealActiveTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _tabKeys[_active]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 160),
      );
    });
  }

  Future<void> _closePage([String? kind]) async {
    final target = kind ?? _active;
    if (target == 'dashboard' || !_open.contains(target)) return;
    await _closeTargets([target]);
  }

  Future<void> _closeMany({required bool keepActive}) async {
    final targets = _open
        .where(
          (kind) => kind != 'dashboard' && (!keepActive || kind != _active),
        )
        .toList();
    await _closeTargets(targets);
  }

  Future<void> _closeTargets(List<String> targets) async {
    if (!mounted || _closing || targets.isEmpty) return;
    final revision = _tabsRevision;
    final snapshot = List<String>.of(_open);
    final active = _active;
    final guards = ref.read(closeGuardsProvider);
    setState(() => _closing = true);
    try {
      for (final kind in targets) {
        if (!await _canCloseKind(kind)) return;
        if (!mounted ||
            revision != _tabsRevision ||
            active != _active ||
            !listEquals(snapshot, _open) ||
            !identical(guards, ref.read(closeGuardsProvider))) {
          return;
        }
      }
      // No await after the final checks: commit all removals together.
      if (targets.any(_kindBusy)) return;
      setState(() {
        for (final kind in targets) {
          _open.remove(kind);
          _tabKeys.remove(kind);
          _pageKeys.remove(kind);
        }
        if (!_open.contains(_active)) _active = _open.last;
        _tabsRevision++;
      });
      _revealActiveTab();
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  void _cycle(bool backwards) {
    if (_closing || _open.length < 2) return;
    final index = _open.indexOf(_active);
    final next = (index + (backwards ? -1 : 1)) % _open.length;
    setState(() {
      _active = _open[next < 0 ? next + _open.length : next];
      _tabsRevision++;
    });
    _revealActiveTab();
  }

  Future<void> _quickSearch() async {
    if (_closing) return;
    final kind = await showDialog<String>(
      context: context,
      builder: (_) => _QuickSearchDialog(pages: widget.pages),
    );
    if (kind != null) _openPage(kind);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final tokens = UiTokens.of(context);
    final accent = tokens.accent;
    final pagesByKind = {for (final page in widget.pages) page.kind: page};
    final locale = ref.watch(localeProvider);
    final formatLocale = ref.watch(formatLocaleProvider);
    final timeZone = ref.watch(regionalTimeZoneProvider);
    final currency = ref.watch(preferredCurrencyProvider);
    final preferencesBlocked = ref
        .watch(preferencesImportGateProvider)
        .blocksWrites;
    final navigation = ref.watch(workspaceNavigationPreferencesProvider);
    String titleOf(String kind) => kind == 'dashboard'
        ? t.uiDashboard
        : pagesByKind[kind]?.title(t) ?? kind;
    final muted = tokens.secondaryText;

    // 只渲染仍注册的 kind；持久化里的未知 kind 直接隐藏，不回写清除。
    final pagesByKindAll = {for (final page in widget.pages) page.kind: page};
    List<UiPage> resolve(Iterable<String> kinds) => [
      for (final kind in kinds)
        if (pagesByKindAll[kind] != null) pagesByKindAll[kind]!,
    ];
    final favoritePages = resolve(navigation.favoriteKinds);
    final favoriteKinds = {for (final page in favoritePages) page.kind};
    final recentPages = [
      for (final page in resolve(navigation.recentKinds))
        if (!favoriteKinds.contains(page.kind)) page,
    ];
    void toggleFavorite(String kind) {
      final ok = ref
          .read(workspaceNavigationPreferencesProvider.notifier)
          .toggleFavorite(kind);
      if (!ok) showToast(context, t.navFavoriteLimit);
    }

    final activePage = pagesByKind[_active];
    final pageCommands = activePage?.commands ?? const <UiCommand>[];
    // 可用性在 build 顶部统一求值：isEnabledProvider 由外壳直接 watch，
    // 页面状态（选中项、忙锁、权限）变化会重建外壳，命令随之更新。
    final enabledCommands = {
      for (final command in pageCommands)
        command.id:
            command.isEnabledProvider == null ||
            ref.watch(command.isEnabledProvider!),
    };
    bool commandEnabled(UiCommand command) =>
        enabledCommands[command.id] ?? true;

    Widget check(bool selected) => SizedBox(
      width: 16,
      child: selected
          ? Icon(FluentIcons.check_mark, size: 12, color: accent)
          : null,
    );

    return CurrentActivitiesNavigation(
      registeredPages: _activityPages,
      onLocate: _closing || _activitiesOpen ? null : _locateActivity,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyW, control: true):
              _closePage,
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _quickSearch,
          const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
              _cycle(false),
          const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
            shift: true,
          ): () =>
              _cycle(true),
        },
        child: Focus(
          autofocus: true,
          child: Container(
            color: theme.scaffoldBackgroundColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MenuBar(
                  items: [
                    MenuBarItem(
                      title: t.menuFile,
                      items: [
                        MenuFlyoutItem(
                          text: Text(t.menuCloseTab),
                          trailing: Text('Ctrl+W', style: _shortcut(muted)),
                          onPressed: _active == 'dashboard'
                              ? null
                              : () => _closePage(),
                        ),
                        MenuFlyoutItem(
                          text: Text(t.menuCloseOthers),
                          onPressed: _open.length <= 1
                              ? null
                              : () => _closeMany(keepActive: true),
                        ),
                        MenuFlyoutItem(
                          text: Text(t.menuCloseAll),
                          onPressed: _open.length <= 1
                              ? null
                              : () => _closeMany(keepActive: false),
                        ),
                      ],
                    ),
                    MenuBarItem(
                      title: t.menuView,
                      items: [
                        MenuFlyoutSubItem(
                          text: Text(t.menuTheme),
                          items: (context) => [
                            for (final (mode, label) in [
                              (KeelThemeMode.system, t.themeSystem),
                              (KeelThemeMode.light, t.themeLight),
                              (KeelThemeMode.dark, t.themeDark),
                            ])
                              MenuFlyoutItem(
                                text: Row(
                                  children: [
                                    check(ref.watch(themeModeProvider) == mode),
                                    Text(label),
                                  ],
                                ),
                                onPressed: () => ref
                                    .read(themeModeProvider.notifier)
                                    .set(mode),
                              ),
                          ],
                        ),
                        MenuFlyoutSubItem(
                          text: Text(t.menuLanguage),
                          items: (context) => [
                            for (final (code, label) in [
                              (null, t.langSystem),
                              ('zh', t.langZh),
                              ('en', t.langEn),
                            ])
                              MenuFlyoutItem(
                                text: Row(
                                  children: [
                                    check(locale?.languageCode == code),
                                    Text(label),
                                  ],
                                ),
                                onPressed: preferencesBlocked
                                    ? null
                                    : () => ref
                                          .read(localeProvider.notifier)
                                          .set(
                                            code == null ? null : Locale(code),
                                          ),
                              ),
                          ],
                        ),
                        MenuFlyoutSubItem(
                          text: Text(t.menuFormatLocale),
                          items: (context) => [
                            for (final (value, label) in <(String?, String)>[
                              (null, t.formatLocaleSystem),
                              ('en_US', t.formatLocaleUs),
                              ('en_GB', t.formatLocaleGb),
                              ('zh_CN', t.formatLocaleCn),
                            ])
                              MenuFlyoutItem(
                                text: Row(
                                  children: [
                                    check(formatLocale == value),
                                    Text(label),
                                  ],
                                ),
                                onPressed: preferencesBlocked
                                    ? null
                                    : () => ref
                                          .read(formatLocaleProvider.notifier)
                                          .set(value),
                              ),
                          ],
                        ),
                        MenuFlyoutSubItem(
                          text: Text(t.menuTimeZone),
                          items: (context) => [
                            for (final (value, label) in <(String?, String)>[
                              (null, t.timeZoneSystem),
                              ('UTC', t.timeZoneUtc),
                            ])
                              MenuFlyoutItem(
                                text: Row(
                                  children: [
                                    check(timeZone == value),
                                    Text(label),
                                  ],
                                ),
                                onPressed: preferencesBlocked
                                    ? null
                                    : () => ref
                                          .read(
                                            regionalSettingsProvider.notifier,
                                          )
                                          .setTimeZone(value),
                              ),
                          ],
                        ),
                        MenuFlyoutSubItem(
                          text: Text(t.menuCurrency),
                          items: (context) => [
                            for (final value in <String?>[
                              null,
                              'CNY',
                              'USD',
                              'EUR',
                              'GBP',
                              'JPY',
                            ])
                              MenuFlyoutItem(
                                text: Tooltip(
                                  message: t.currencyPreferenceNotice,
                                  child: Row(
                                    children: [
                                      check(currency == value),
                                      Text(value ?? t.currencyUnspecified),
                                    ],
                                  ),
                                ),
                                onPressed: preferencesBlocked
                                    ? null
                                    : () => ref
                                          .read(
                                            regionalSettingsProvider.notifier,
                                          )
                                          .setCurrency(value),
                              ),
                          ],
                        ),
                      ],
                    ),
                    MenuBarItem(
                      title: t.menuTools,
                      items: [
                        if (pageCommands.isEmpty)
                          MenuFlyoutItem(
                            text: Text(t.noPageCommands),
                            onPressed: null,
                          ),
                        for (final command in pageCommands)
                          MenuFlyoutItem(
                            text: Text(command.label(t)),
                            trailing: command.shortcutHint == null
                                ? null
                                : Text(
                                    command.shortcutHint!,
                                    style: _shortcut(muted),
                                  ),
                            onPressed: commandEnabled(command)
                                ? () => command.onInvoke(context, ref)
                                : null,
                          ),
                      ],
                    ),
                    MenuBarItem(
                      title: t.menuWindow,
                      items: [
                        MenuFlyoutItem(
                          text: Text(t.menuOpenPage),
                          trailing: Text('Ctrl+K', style: _shortcut(muted)),
                          onPressed: _quickSearch,
                        ),
                        MenuFlyoutItem(
                          text: Text(t.menuNextTab),
                          trailing: Text('Ctrl+Tab', style: _shortcut(muted)),
                          onPressed: _open.length < 2
                              ? null
                              : () => _cycle(false),
                        ),
                        MenuFlyoutItem(
                          text: Text(t.menuPreviousTab),
                          trailing: Text(
                            'Ctrl+Shift+Tab',
                            style: _shortcut(muted),
                          ),
                          onPressed: _open.length < 2
                              ? null
                              : () => _cycle(true),
                        ),
                      ],
                    ),
                    MenuBarItem(
                      title: t.menuHelp,
                      items: [
                        MenuFlyoutItem(
                          text: Text(t.menuAbout),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (context) => ContentDialog(
                              title: Text(t.appTitle),
                              content: Text('Keel · Fluent UI'),
                              actions: [
                                Button(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text(t.actionClose),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                _GlobalNotices(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: navigation.navCollapsed
                            ? UiSize.sidebarCollapsed
                            : UiSize.sidebar,
                        color: tokens.colors.menu,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: EdgeInsetsDirectional.fromSTEB(
                                navigation.navCollapsed ? 4 : 16,
                                8,
                                4,
                                4,
                              ),
                              child: Row(
                                children: [
                                  if (!navigation.navCollapsed)
                                    Expanded(
                                      child: Text(
                                        t.navSidebarTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.typography.caption
                                            ?.copyWith(
                                              color: muted,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.6,
                                            ),
                                      ),
                                    ),
                                  Tooltip(
                                    message: navigation.navCollapsed
                                        ? t.navExpand
                                        : t.navCollapse,
                                    child: IconButton(
                                      key: const ValueKey('nav-collapse'),
                                      icon: Icon(
                                        navigation.navCollapsed
                                            ? FluentIcons.chevron_right
                                            : FluentIcons.chevron_left,
                                        size: 12,
                                      ),
                                      onPressed: () => ref
                                          .read(
                                            workspaceNavigationPreferencesProvider
                                                .notifier,
                                          )
                                          .setNavCollapsed(
                                            !navigation.navCollapsed,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView(
                                key: const ValueKey('nav-list'),
                                padding: EdgeInsetsDirectional.fromSTEB(
                                  navigation.navCollapsed ? 4 : 8,
                                  2,
                                  navigation.navCollapsed ? 4 : 8,
                                  10,
                                ),
                                children: navigation.navCollapsed
                                    ? [
                                        _NavIconButton(
                                          kind: 'dashboard',
                                          icon: FluentIcons.home,
                                          label: t.uiDashboard,
                                          selected: _active == 'dashboard',
                                          accent: accent,
                                          onPressed: () =>
                                              _openPage('dashboard'),
                                        ),
                                        for (final page in widget.pages)
                                          _NavIconButton(
                                            kind: page.kind,
                                            icon: page.icon,
                                            label:
                                                page.navTitle?.call(t) ??
                                                page.title(t),
                                            selected: _active == page.kind,
                                            accent: accent,
                                            onPressed: () =>
                                                _openPage(page.kind),
                                          ),
                                      ]
                                    : [
                                        _NavButton(
                                          key: const ValueKey('nav-dashboard'),
                                          icon: FluentIcons.home,
                                          label: t.uiDashboard,
                                          selected: _active == 'dashboard',
                                          accent: accent,
                                          onPressed: () =>
                                              _openPage('dashboard'),
                                        ),
                                        _NavSectionLabel(label: t.navModules),
                                        for (final page in widget.pages)
                                          if (!favoriteKinds.contains(
                                            page.kind,
                                          ))
                                            _NavRow(
                                              page: page,
                                              label:
                                                  page.navTitle?.call(t) ??
                                                  page.title(t),
                                              selected: _active == page.kind,
                                              favorite: false,
                                              accent: accent,
                                              muted: muted,
                                              onPressed: () =>
                                                  _openPage(page.kind),
                                              onFavorite: () =>
                                                  toggleFavorite(page.kind),
                                            ),
                                        _NavSectionLabel(label: t.navFavorites),
                                        if (favoritePages.isEmpty)
                                          _NavEmptyHint(
                                            text: t.navFavoritesEmpty,
                                          )
                                        else
                                          for (final page in favoritePages)
                                            _NavRow(
                                              page: page,
                                              label:
                                                  page.navTitle?.call(t) ??
                                                  page.title(t),
                                              selected: _active == page.kind,
                                              favorite: true,
                                              accent: accent,
                                              muted: muted,
                                              onPressed: () =>
                                                  _openPage(page.kind),
                                              onFavorite: () =>
                                                  toggleFavorite(page.kind),
                                            ),
                                        // 最近访问为空时整段不出现：页签已经表达「开着的页面」，
                                        // 一条「暂无最近访问」的提示只是占位噪声。
                                        if (recentPages.isNotEmpty) ...[
                                          _NavSectionLabel(label: t.navRecent),
                                          for (final page in recentPages)
                                            _NavRow(
                                              page: page,
                                              label:
                                                  page.navTitle?.call(t) ??
                                                  page.title(t),
                                              selected: _active == page.kind,
                                              favorite: false,
                                              accent: accent,
                                              muted: muted,
                                              onPressed: () =>
                                                  _openPage(page.kind),
                                              onFavorite: () =>
                                                  toggleFavorite(page.kind),
                                            ),
                                        ],
                                      ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(width: 1, color: tokens.divider),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 页签与「当前页命令」同一行：命令跟着活动页走，不另占一条
                            // 全局工具条；页面名只在页签上出现一次，不再重复。
                            Container(
                              key: const ValueKey('page-toolbar'),
                              height: UiSize.tabBar,
                              decoration: BoxDecoration(
                                color: tokens.colors.panel,
                                border: Border(
                                  bottom: BorderSide(color: tokens.divider),
                                ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final commandWidth =
                                      (constraints.maxWidth - 180).clamp(
                                        0.0,
                                        560.0,
                                      );
                                  return Row(
                                    children: [
                                      Expanded(
                                        child: ListView(
                                          scrollDirection: Axis.horizontal,
                                          children: [
                                            for (final kind in _open)
                                              _TabButton(
                                                key: _tabKeys.putIfAbsent(
                                                  kind,
                                                  () => GlobalKey(
                                                    debugLabel: 'tab-$kind',
                                                  ),
                                                ),
                                                label: titleOf(kind),
                                                selected: kind == _active,
                                                accent: accent,
                                                onPressed: () =>
                                                    _openPage(kind),
                                                onClose: kind == 'dashboard'
                                                    ? null
                                                    : () => _closePage(kind),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (pageCommands.isNotEmpty &&
                                          commandWidth > 80) ...[
                                        Container(
                                          width: 1,
                                          height: 16,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          color: tokens.divider,
                                        ),
                                        ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: commandWidth,
                                          ),
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Row(
                                              children: [
                                                for (final command
                                                    in pageCommands)
                                                  _ToolbarButton(
                                                    buttonKey: ValueKey(
                                                      'command-${command.id}',
                                                    ),
                                                    icon:
                                                        command.icon ??
                                                        FluentIcons.play,
                                                    label: command.label(t),
                                                    onPressed:
                                                        commandEnabled(command)
                                                        ? () =>
                                                              command.onInvoke(
                                                                context,
                                                                ref,
                                                              )
                                                        : null,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 4),
                                      _ToolbarIconButton(
                                        key: const ValueKey('toolbar-search'),
                                        icon: FluentIcons.search,
                                        tooltip: t.menuOpenPage,
                                        onPressed: _quickSearch,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                  );
                                },
                              ),
                            ),
                            Expanded(
                              child: IndexedStack(
                                index: _open.indexOf(_active),
                                children: [
                                  for (final kind in _open)
                                    KeyedSubtree(
                                      key: _pageKeys.putIfAbsent(
                                        kind,
                                        () =>
                                            GlobalKey(debugLabel: 'page-$kind'),
                                      ),
                                      child: IgnorePointer(
                                        ignoring: _closing,
                                        child: ExcludeFocus(
                                          excluding:
                                              kind != _active || _closing,
                                          child: TickerMode(
                                            enabled:
                                                kind == _active && !_closing,
                                            child: kind == 'dashboard'
                                                ? DashboardPage(
                                                    pages: widget.pages,
                                                    onOpen: _openPage,
                                                  )
                                                : pagesByKind[kind]!.builder(
                                                    context,
                                                    () => _openPage(kind),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusBar(
                  onOpenPage: _openPage,
                  onShowActivities: _closing ? null : _showCurrentActivities,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle? _shortcut(Color? color) => TextStyle(fontSize: 11, color: color);

class _NavButton extends StatelessWidget {
  const _NavButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Button(
        onPressed: onPressed,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => selected
                ? tokens.accentBackground
                : states.isHovered
                ? tokens.hoverOverlay
                : Colors.transparent,
          ),
          foregroundColor: WidgetStatePropertyAll(
            selected ? accent : tokens.foreground,
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsetsDirectional.only(start: 7, end: 10),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          height: UiSize.navRow,
          child: Row(
            children: [
              // 选中指示条：只靠 10% 底色在白侧栏上几乎看不出，必须给位置。
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: selected ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Icon(icon, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavEmptyHint extends StatelessWidget {
  const _NavEmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 10, 6),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: tokens.caption?.copyWith(color: tokens.emptyText),
      ),
    );
  }
}

class _NavSectionLabel extends StatelessWidget {
  const _NavSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 14, 10, 4),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.caption?.copyWith(
          color: tokens.emptyText,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 侧栏一行：导航按钮 + 收藏切换。key 用稳定的 kind，方便测试与读屏。
///
/// 星标只在「已收藏」或「鼠标悬停该行」时显形，宽度始终预留 24，避免行内跳动；
/// 热区固定 24×24（此前 12px 图标约 20 的可点区域容易点错）。
class _NavRow extends StatefulWidget {
  const _NavRow({
    required this.page,
    required this.label,
    required this.selected,
    required this.favorite,
    required this.accent,
    required this.muted,
    required this.onPressed,
    required this.onFavorite,
  });

  final UiPage page;
  final String label;
  final bool selected;
  final bool favorite;
  final Color accent;
  final Color? muted;
  final VoidCallback onPressed;
  final VoidCallback onFavorite;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final t = AppLocalizations.of(context);
    final reveal = widget.favorite || _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        children: [
          Expanded(
            child: _NavButton(
              key: ValueKey('nav-${widget.page.kind}'),
              icon: widget.page.icon,
              label: widget.label,
              selected: widget.selected,
              accent: widget.accent,
              onPressed: widget.onPressed,
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 2),
            child: AnimatedOpacity(
              opacity: reveal ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Tooltip(
                message: widget.favorite
                    ? t.navRemoveFavorite
                    : t.navAddFavorite,
                child: Button(
                  key: ValueKey('nav-favorite-${widget.page.kind}'),
                  onPressed: widget.onFavorite,
                  style: ButtonStyle(
                    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.isHovered
                          ? tokens.hoverOverlay
                          : Colors.transparent,
                    ),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: Icon(
                      widget.favorite
                          ? FluentIcons.favorite_star_fill
                          : FluentIcons.favorite_star,
                      size: 12,
                      color: widget.favorite
                          ? widget.accent
                          : widget.muted ?? tokens.emptyText,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 折叠后的图标导航；label 只进 tooltip 与语义。
class _NavIconButton extends StatelessWidget {
  const _NavIconButton({
    required this.kind,
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onPressed,
  });

  final String kind;
  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Button(
          key: ValueKey('nav-$kind'),
          onPressed: onPressed,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => selected
                  ? tokens.accentBackground
                  : states.isHovered
                  ? tokens.hoverOverlay
                  : Colors.transparent,
            ),
            foregroundColor: WidgetStatePropertyAll(
              selected ? accent : tokens.foreground,
            ),
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
          child: SizedBox(
            width: 40,
            height: UiSize.navRow,
            child: Icon(icon, size: 18),
          ),
        ),
      ),
    );
  }
}

/// 页面级命令按钮：26 高、12 号字，hover 才出底色；禁用时降到辅助色。
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// key 挂在真正的 [Button] 上，测试与读屏都拿它判断可用性。
  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Tooltip(
        message: label,
        child: Button(
          key: buttonKey,
          onPressed: onPressed,
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 8),
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.isHovered && onPressed != null
                  ? tokens.hoverOverlay
                  : Colors.transparent,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => onPressed == null
                  ? tokens.emptyText
                  : states.isHovered
                  ? tokens.foreground
                  : tokens.secondaryText,
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
          child: SizedBox(
            height: 26,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具条右侧的图标按钮（搜索）：热区固定 26×26。
class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Button(
        onPressed: onPressed,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.isHovered ? tokens.hoverOverlay : Colors.transparent,
          ),
          foregroundColor: WidgetStatePropertyAll(tokens.secondaryText),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        child: SizedBox(width: 26, height: 26, child: Icon(icon, size: 13)),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onPressed,
    this.onClose,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onPressed;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final foreground = selected ? tokens.foreground : tokens.secondaryText;
    return Tooltip(
      message: label,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          // 选中页签取画布色：和下方内容同色，页签才「长」在内容上，
          // 而不是浮在工具条上的一块白卡。
          color: selected ? tokens.colors.page : Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        ),
        child: Column(
          children: [
            // 选中用「顶部 2px 主色 + 白色页签」表达，未选中与内容同底、不画边框。
            Container(height: 2, color: selected ? accent : Colors.transparent),
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Button(
                    onPressed: onPressed,
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) => selected || !states.isHovered
                            ? Colors.transparent
                            : tokens.hoverOverlay,
                      ),
                      padding: WidgetStatePropertyAll(
                        EdgeInsetsDirectional.only(
                          start: 12,
                          end: onClose == null ? 12 : 4,
                        ),
                      ),
                      shape: const WidgetStatePropertyAll(
                        RoundedRectangleBorder(),
                      ),
                      foregroundColor: WidgetStatePropertyAll(foreground),
                    ),
                    child: SizedBox(
                      height: 32,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 168),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.start,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: foreground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (onClose != null)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Button(
                        onPressed: onClose,
                        style: ButtonStyle(
                          padding: const WidgetStatePropertyAll(
                            EdgeInsets.zero,
                          ),
                          backgroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.isHovered
                                ? tokens.hoverOverlay
                                : Colors.transparent,
                          ),
                          shape: WidgetStatePropertyAll(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          foregroundColor: WidgetStatePropertyAll(
                            tokens.secondaryText,
                          ),
                        ),
                        child: const SizedBox(
                          width: 20,
                          height: 20,
                          child: Icon(FluentIcons.chrome_close, size: 9),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.onOpenPage, required this.onShowActivities});

  final void Function(String kind) onOpenPage;
  final VoidCallback? onShowActivities;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final status = ref.watch(appStatusProvider).value;
    final user = ref.watch(currentUserProvider).value;
    final tokens = UiTokens.of(context);
    final accent = tokens.accent;
    final muted = tokens.secondaryText;
    final activities = ref
        .watch(currentActivitiesProvider)
        .map((activity) => currentActivityLabel(t, activity))
        .toList();
    Widget item(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: child,
    );
    return Container(
      // 高度贴合内容：22 是目标值，文字放大时允许长高而不是被裁掉。
      constraints: const BoxConstraints(minHeight: UiSize.statusBar),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tokens.colors.menu,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          // 左侧信息收成一组：数据库状态 → 版本 → 进行中任务都在左边，
          // 不再被 spaceBetween 摊到整条状态栏的中间去。
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  item(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: status?.databaseReady == true
                                ? tokens.colors.success
                                : tokens.colors.danger,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status?.databaseReady == true
                              ? t.statusDbReady
                              : t.statusDbUnavailable,
                          style: tokens.caption?.copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  item(
                    Text(
                      status == null ? '—' : t.statusVersion(status.version),
                      style: tokens.caption?.copyWith(color: muted),
                    ),
                  ),
                  if (activities.isNotEmpty)
                    item(
                      Tooltip(
                        message: activities.join('\n'),
                        child: Semantics(
                          liveRegion: true,
                          label: activities.join(', '),
                          child: Button(
                            key: const ValueKey('current-activities-details'),
                            onPressed:
                                ModalRoute.of(context)?.isCurrent == false
                                ? null
                                : onShowActivities,
                            style: ButtonStyle(
                              padding: const WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 6),
                              ),
                              shape: const WidgetStatePropertyAll(
                                RoundedRectangleBorder(),
                              ),
                              backgroundColor: const WidgetStatePropertyAll(
                                Colors.transparent,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: ProgressRing(
                                    strokeWidth: 2,
                                    activeColor: accent,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  t.statusActiveOperations(activities.length),
                                  style: tokens.caption?.copyWith(color: muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          _UserMenu(user: user, accent: accent, onOpenPage: onOpenPage),
        ],
      ),
    );
  }
}

class _UserMenu extends ConsumerStatefulWidget {
  const _UserMenu({
    required this.user,
    required this.accent,
    required this.onOpenPage,
  });

  final UserInfo? user;
  final Color accent;
  final void Function(String kind) onOpenPage;

  @override
  ConsumerState<_UserMenu> createState() => _UserMenuState();
}

class _UserMenuState extends ConsumerState<_UserMenu> {
  final _controller = FlyoutController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _roleLabel(AppLocalizations t, String role) => switch (role) {
    'admin' => t.roleAdmin,
    'operator' => t.roleOperator,
    _ => t.roleViewer,
  };

  Future<void> _lock() async {
    final t = AppLocalizations.of(context);
    try {
      await ref.read(authServiceProvider).lock();
      if (!mounted) return;
      ref.invalidate(authStatusProvider);
      ref.invalidate(currentUserProvider);
    } catch (error) {
      if (!mounted) return;
      showToast(context, errorText(t, error), severity: InfoBarSeverity.error);
    }
  }

  Future<void> _switchTo(String name) async {
    final t = AppLocalizations.of(context);
    try {
      await ref.read(userServiceProvider).switchTo(name);
      if (!mounted) return;
      ref.invalidate(currentUserProvider);
    } catch (error) {
      if (!mounted) return;
      showToast(context, errorText(t, error), severity: InfoBarSeverity.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final user = widget.user;
    if (user == null) return const SizedBox.shrink();
    final names =
        ref.watch(usersProvider).value?.map((u) => u.name).toList() ??
        [user.name];
    return FlyoutTarget(
      controller: _controller,
      child: Button(
        onPressed: () {
          _controller.showFlyout<void>(
            placementMode: FlyoutPlacementMode.topCenter,
            builder: (context) => MenuFlyout(
              items: [
                for (final name in names)
                  MenuFlyoutItem(
                    text: Text(name),
                    trailing: name == user.name
                        ? Icon(
                            FluentIcons.check_mark,
                            size: 12,
                            color: widget.accent,
                          )
                        : null,
                    onPressed: name == user.name
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            _switchTo(name);
                          },
                  ),
                const MenuFlyoutSeparator(),
                if (ref.watch(authStatusProvider).value?.loginRequired ?? false)
                  MenuFlyoutItem(
                    text: Text(t.securityLockNow),
                    onPressed: () {
                      Navigator.of(context).pop();
                      _lock();
                    },
                  ),
                MenuFlyoutItem(
                  text: Text(t.menuNewUser),
                  onPressed: hasPermission(user, 'users.manage')
                      ? () {
                          Navigator.of(context).pop();
                          widget.onOpenPage('new-user');
                        }
                      : null,
                ),
              ],
            ),
          );
        },
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.accent,
              ),
              child: Text(
                user.name.isEmpty
                    ? '?'
                    : user.name.substring(0, 1).toUpperCase(),
                style: const TextStyle(fontSize: 9, color: Colors.white),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${user.name} · ${_roleLabel(t, user.role)}',
              style: theme.typography.caption,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickSearchDialog extends StatefulWidget {
  const _QuickSearchDialog({required this.pages});

  final List<UiPage> pages;

  @override
  State<_QuickSearchDialog> createState() => _QuickSearchDialogState();
}

class _QuickSearchDialogState extends State<_QuickSearchDialog> {
  final _query = TextEditingController();
  String _text = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final muted = UiTokens.of(context).secondaryText;
    final matches = widget.pages.where((page) {
      final title = page.title(t).toLowerCase();
      return _text.isEmpty ||
          title.contains(_text) ||
          page.kind.toLowerCase().contains(_text);
    }).toList();
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 440, maxHeight: 520),
      title: Text(t.menuOpenPage),
      content: SizedBox(
        height: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextBox(
              controller: _query,
              autofocus: true,
              placeholder: t.searchHint,
              prefix: const Padding(
                padding: EdgeInsetsDirectional.only(start: 8),
                child: Icon(FluentIcons.search, size: 12),
              ),
              onChanged: (value) => setState(() => _text = value.toLowerCase()),
              onSubmitted: (_) {
                if (matches.isNotEmpty) {
                  Navigator.of(context).pop(matches.first.kind);
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        t.quickPageSearchEmpty,
                        style: UiTokens.of(context).caption
                            ?.copyWith(color: muted),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final page in matches)
                          Button(
                            onPressed: () =>
                                Navigator.of(context).pop(page.kind),
                            style: ButtonStyle(
                              backgroundColor: const WidgetStatePropertyAll(
                                Colors.transparent,
                              ),
                              shape: const WidgetStatePropertyAll(
                                RoundedRectangleBorder(),
                              ),
                              padding: const WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              child: Row(
                                children: [
                                  Icon(page.icon, size: 14),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(page.title(t))),
                                  Text(
                                    page.kind,
                                    style: UiTokens.of(context).caption
                                        ?.copyWith(color: muted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
      ],
    );
  }
}

/// 应用级提示：数据库不可用/重试、设置保存失败、启动恢复结果。
class _GlobalNotices extends ConsumerWidget {
  const _GlobalNotices();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final db = ref.watch(databaseRecoveryProvider);
    final status = ref.watch(appStatusProvider).value;
    final save = ref.watch(settingsSaveProvider);
    final restore = ref.watch(startupRestoreProvider);
    final dismissed = ref.watch(startupRestoreDismissedProvider);
    final outcome = restore.value?.outcome;
    final notices = <Widget>[
      if (db.error != null)
        InfoBar(
          severity: InfoBarSeverity.error,
          title: Text(errorText(t, db.error!)),
          action: Button(
            onPressed: db.retrying
                ? null
                : () => ref.read(databaseRecoveryProvider.notifier).retry(),
            child: Text(t.actionRetryDatabase),
          ),
        ),
      if (status != null && !status.databaseReady)
        InfoBar(
          severity: InfoBarSeverity.warning,
          title: Text(t.statusDbUnavailable),
          action: Button(
            onPressed: db.retrying
                ? null
                : () => ref.read(databaseRecoveryProvider.notifier).retry(),
            child: Text(t.actionRetryDatabase),
          ),
        ),
      if (save.error != null)
        InfoBar(
          severity: InfoBarSeverity.error,
          title: Text(errorText(t, save.error!)),
          action: Button(
            onPressed: save.saving
                ? null
                : () => ref.read(settingsSaveProvider.notifier).retry(),
            child: Text(t.actionRetrySave),
          ),
        ),
      if (!dismissed &&
          restore.hasValue &&
          outcome != null &&
          outcome != 'none')
        InfoBar(
          severity: outcome == 'restored'
              ? InfoBarSeverity.success
              : InfoBarSeverity.warning,
          title: Text(
            outcome == 'restored'
                ? t.startupRestoreDone
                : t.startupRestoreFailed,
          ),
          onClose: () =>
              ref.read(startupRestoreDismissedProvider.notifier).state = true,
        ),
    ];
    if (notices.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final notice in notices)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: notice),
        ],
      ),
    );
  }
}
