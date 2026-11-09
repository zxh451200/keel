import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/ui/tokens.dart';

/// 页面标题与说明的统一排版。
class UiPageHeader extends StatelessWidget {
  const UiPageHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: tokens.pageTitle),
        if (subtitle != null) ...[
          const SizedBox(height: UiTokens.titleGap),
          // A hint must not grow without bound: at large text scales a long
          // subtitle would starve the page body.
          Text(
            subtitle!,
            style: tokens.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// 内容卡片：可选标题行、主体、可选底栏。
class UiPanel extends StatelessWidget {
  const UiPanel({
    super.key,
    this.header,
    required this.child,
    this.footer,
    this.expand = false,
    this.padding = UiTokens.panelPadding,
  });

  final Widget? header;
  final Widget child;
  final Widget? footer;
  final bool expand;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final tokens = UiTokens.of(context);
    final body = padding == EdgeInsets.zero
        ? child
        : Padding(padding: padding, child: child);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: UiTokens.panelRadius,
        border: Border.all(color: tokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) ...[
            Container(
              padding: UiTokens.panelHeaderPadding,
              color: tokens.panelHeaderBackground,
              child: header!,
            ),
            Container(height: UiTokens.dividerThickness, color: tokens.divider),
          ],
          if (expand) Expanded(child: body) else body,
          if (footer != null) ...[
            Container(height: UiTokens.dividerThickness, color: tokens.divider),
            Padding(padding: UiTokens.panelFooterPadding, child: footer!),
          ],
        ],
      ),
    );
  }
}

/// 整页滚动兜底：窗口高度不足时让页面滚动，并按 [minExtent] 布局内容。
///
/// 高 DPI 下的最小窗口（1280×720 @200% = 640×360）去掉外壳后只剩一百多像素，
/// 固定页头 + 多行筛选项会把表格挤成 RenderFlex 溢出。高度够时行为不变。
class UiScrollablePage extends StatelessWidget {
  const UiScrollablePage({
    super.key,
    required this.child,
    this.minExtent = 640,
  });

  final Widget child;
  final double minExtent;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight >= minExtent) return child;
        return SingleChildScrollView(
          child: SizedBox(height: minExtent, child: child),
        );
      },
    );
  }
}

/// 卡片内空状态。
class UiEmpty extends StatelessWidget {
  const UiEmpty({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final content = Padding(
      padding: UiTokens.emptyPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: tokens.emptyText),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: tokens.body?.copyWith(color: tokens.emptyText),
          ),
        ],
      ),
    );
    // 被挤到小于内容高度时（最小窗口 + 多行筛选项）滚动显示，而不是溢出。
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight.isInfinite) return Center(child: content);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

/// 轻量单行提示。
class UiNotice extends StatelessWidget {
  const UiNotice({super.key, required this.message, this.severity});

  final String message;
  final InfoBarSeverity? severity;

  @override
  Widget build(BuildContext context) {
    return InfoBar(
      severity: severity ?? InfoBarSeverity.info,
      title: Text(message),
    );
  }
}

void showToast(
  BuildContext context,
  String message, {
  InfoBarSeverity severity = InfoBarSeverity.success,
}) {
  displayInfoBar(
    context,
    builder: (context, close) =>
        InfoBar(title: Text(message), severity: severity, onClose: close),
  );
}
