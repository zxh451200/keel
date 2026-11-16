import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/tokens.dart';

/// 首页概览：一句真实状态摘要 + 最近访问 + 带用途说明的模块入口。
///
/// 刻意不重复底部状态栏的信息：数据库与版本只在状态栏出现一次，首页只保留
/// 一行「健康点 + 摘要」。数据库不可用时该行变红并同步显示为不可用文案，颜色
/// 不是唯一线索。最近访问与侧栏同源，已收藏的入口不回显。
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key, required this.pages, required this.onOpen});

  final List<UiPage> pages;
  final void Function(String kind) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final tokens = UiTokens.of(context);
    final status = ref.watch(appStatusProvider).value;
    final navigation = ref.watch(workspaceNavigationPreferencesProvider);

    final byKind = {for (final page in pages) page.kind: page};
    final favoriteKinds = navigation.favoriteKinds.toSet();
    final recents = <UiPage>[
      for (final kind in navigation.recentKinds)
        if (!favoriteKinds.contains(kind) && byKind.containsKey(kind))
          byKind[kind]!,
    ].take(4).toList();

    final ready = status?.databaseReady == true;
    final summary = [
      ready ? t.statusDbReady : t.statusDbUnavailable,
      t.dashboardSummary(pages.length),
    ].join(' · ');

    return SingleChildScrollView(
      padding: UiTokens.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.uiDashboard, style: tokens.dashboardTitle),
          const SizedBox(height: 8),
          Semantics(
            label: summary,
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: ready ? tokens.colors.success : tokens.colors.danger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    summary,
                    style: tokens.description,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UiTokens.gapXl),
          if (recents.isNotEmpty) ...[
            _SectionHeader(label: t.dashboardRecent),
            const SizedBox(height: UiTokens.gapMd),
            Wrap(
              spacing: UiTokens.gapSm,
              runSpacing: UiTokens.gapSm,
              children: [
                for (final page in recents)
                  _RecentChip(
                    icon: page.icon,
                    label: page.title(t),
                    onPressed: () => onOpen(page.kind),
                  ),
              ],
            ),
            const SizedBox(height: UiTokens.gapXl),
          ],
          _SectionHeader(label: t.navModules),
          const SizedBox(height: UiTokens.gapMd),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = UiTokens.gapMd;
              final columns =
                  ((constraints.maxWidth + spacing) / (232 + spacing))
                      .floor()
                      .clamp(1, 6);
              final cardWidth =
                  (constraints.maxWidth - (columns - 1) * spacing) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final page in pages)
                    SizedBox(
                      width: cardWidth,
                      // 只定宽、给最小高度：固定高度在 200% 文本缩放下会被撑破
                      // （RenderFlex overflow），这里让说明换行后自然长高。
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 132),
                        child: _ModuleCard(
                          icon: page.icon,
                          title: page.title(t),
                          description: _moduleDescription(t, page.kind),
                          onPressed: () => onOpen(page.kind),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 模块用途说明。未登记的 kind 返回 null，卡片退回「只有标题」的紧凑形态，
/// 不会显示空白占位。
String? _moduleDescription(AppLocalizations t, String kind) => switch (kind) {
  'audit' => t.dashboardModuleAudit,
  'diagnostics' => t.dashboardModuleDiagnostics,
  'backup' => t.dashboardModuleBackup,
  'customers' => t.dashboardModuleCustomers,
  'new-user' => t.dashboardModuleNewUser,
  'security' => t.dashboardModuleSecurity,
  'settings-import' => t.dashboardModuleSettingsImport,
  'tasks' => t.dashboardModuleTasks,
  'samples' => t.dashboardModuleSamples,
  'form_samples' => t.dashboardModuleFormSamples,
  _ => null,
};

/// 区块标题 + 延伸到右侧的细线，用来在视觉上把区块「切开」而不是靠留白。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Row(
      children: [
        Text(label, style: tokens.sectionTitle),
        const SizedBox(width: UiTokens.gapMd),
        Expanded(child: Container(height: 1, color: tokens.border)),
      ],
    );
  }
}

/// 最近访问：胶囊形态，与模块卡区分开，避免首屏出现两组一样的白卡。
class _RecentChip extends StatefulWidget {
  const _RecentChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_RecentChip> createState() => _RecentChipState();
}

class _RecentChipState extends State<_RecentChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hovered ? tokens.accentBackground : tokens.colors.panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _hovered ? tokens.colors.borderStrong : tokens.border,
          ),
        ),
        child: Button(
          onPressed: widget.onPressed,
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 14,
                  color: _hovered ? tokens.accent : tokens.secondaryText,
                ),
                const SizedBox(width: 6),
                // 长页面标题在受限行宽（Wrap 整行、小窗口）下必须截断，
                // 否则 chip 固有宽度会把行撑出横向溢出。
                Flexible(
                  child: Text(
                    widget.label,
                    style: tokens.small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// 模块入口卡：图标行 + 标题 + 一行用途说明。
///
/// 说明放在标题下方而不是与图标并排：并排时图标、箭头和留白会吃掉一半宽度，
/// 说明必然被压成省略号。静态态刻意保持中性（白底 + 细边框），悬停时才抬升、
/// 图标转强调色、箭头变实。
class _ModuleCard extends StatefulWidget {
  const _ModuleCard({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.description,
  });

  final IconData icon;
  final String title;
  final String? description;
  final VoidCallback onPressed;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final accent = tokens.accent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // 视觉（底色/描边/阴影）由外层容器负责，Button 只提供焦点与点击语义。
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: tokens.colors.panel,
          borderRadius: UiTokens.panelRadius,
          border: Border.all(
            color: _hovered ? tokens.colors.borderStrong : tokens.border,
          ),
          boxShadow: _hovered ? UiTokens.cardShadow : null,
        ),
        child: Button(
          onPressed: widget.onPressed,
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _hovered
                            ? tokens.accentBackground
                            : tokens.colors.sunken,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: tokens.subtleBorder),
                      ),
                      child: Icon(
                        widget.icon,
                        size: 18,
                        color: _hovered ? accent : tokens.secondaryText,
                      ),
                    ),
                    const Spacer(),
                    AnimatedOpacity(
                      opacity: _hovered ? 1 : 0.35,
                      duration: const Duration(milliseconds: 140),
                      child: Icon(
                        FluentIcons.chevron_right,
                        size: UiSize.iconChevron,
                        color: _hovered ? accent : tokens.secondaryText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                  style: tokens.bodyStrong,
                ),
                if (widget.description case final description?) ...[
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.caption?.copyWith(
                      color: tokens.secondaryText,
                    ),
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
