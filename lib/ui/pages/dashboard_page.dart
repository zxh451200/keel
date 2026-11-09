import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/tokens.dart';

/// 新 Fluent 界面首页：状态概览 + 模块入口。
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key, required this.pages, required this.onOpen});

  final List<UiPage> pages;
  final void Function(String kind) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final tokens = UiTokens.of(context);
    final accent = tokens.accent;
    final status = ref.watch(appStatusProvider).value;
    final user = ref.watch(currentUserProvider).value;
    final soft = tokens.secondaryText;

    return SingleChildScrollView(
      padding: UiTokens.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.uiDashboard, style: tokens.dashboardTitle),
          const SizedBox(height: UiTokens.titleGap),
          Text(t.appTitle, style: tokens.description),
          const SizedBox(height: 22),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _StatusPill(
                icon: FluentIcons.database,
                label: status?.databaseReady == true
                    ? t.statusDbReady
                    : t.statusDbUnavailable,
                color: status?.databaseReady == true
                    ? tokens.colors.success
                    : tokens.colors.danger,
              ),
              _StatusPill(
                icon: FluentIcons.info,
                label: status == null ? '—' : t.statusVersion(status.version),
                color: accent,
              ),
              _StatusPill(
                icon: FluentIcons.contact,
                label: user == null
                    ? '—'
                    : t.statusUser(user.name, _roleLabel(t, user.role)),
                color: accent,
              ),
            ],
          ),
          const SizedBox(height: UiTokens.sectionGap),
          Text(t.navModules, style: tokens.sectionTitle),
          const SizedBox(height: UiTokens.contentGap),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = UiTokens.contentGap;
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
                      height: 92,
                      child: Button(
                        onPressed: () => onOpen(page.kind),
                        style: ButtonStyle(
                          backgroundColor: WidgetStatePropertyAll(
                            theme.cardColor,
                          ),
                          padding: const WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 16),
                          ),
                          shape: WidgetStatePropertyAll(
                            RoundedRectangleBorder(
                              borderRadius: UiTokens.panelRadius,
                            ),
                          ),
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: tokens.accentBackground,
                                  borderRadius: UiTokens.panelRadius,
                                ),
                                child: Icon(page.icon, size: 18, color: accent),
                              ),
                              const SizedBox(width: UiTokens.contentGap),
                              Expanded(
                                child: Text(
                                  page.title(t),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.start,
                                  style: theme.typography.bodyStrong,
                                ),
                              ),
                              Icon(
                                FluentIcons.chevron_right,
                                size: 12,
                                color: soft,
                              ),
                            ],
                          ),
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

String _roleLabel(AppLocalizations t, String role) => switch (role) {
  'admin' => t.roleAdmin,
  'operator' => t.roleOperator,
  'viewer' => t.roleViewer,
  _ => '—',
};

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: UiTokens.compactPadding,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: UiTokens.compactRadius,
        border: Border.all(color: UiTokens.of(context).subtleBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          // The pill sits in a Wrap: at high DPI the label can exceed the
          // remaining width, so it must shrink instead of overflowing.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: UiTokens.of(context).caption,
            ),
          ),
        ],
      ),
    );
  }
}
