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

/// 整页滚动兜底：窗口高度不足时让页面滚动，并按 [narrowMinExtent] 布局内容。
///
/// 页面主体（表格/列表）本身已经是滚动区，整页滚动条只在固定部分（页头 +
/// 筛选/操作条）摆不下时才有意义。固定部分的高度随宽度变化：窄页面上按钮
/// 会折成多行，需要更早回退；宽页面在 420 以上就能安全让主体自己滚动。
/// 阈值设得过高（曾用 640）会让 1280×720 @125% 这类常见窗口也出现整页滚动条，
/// 与主体滚动条叠成双层滚动。
class UiScrollablePage extends StatelessWidget {
  const UiScrollablePage({
    super.key,
    required this.child,
    this.narrowMinExtent = 640,
  });

  /// 回退时的布局高度，同时是窄页面的回退阈值。沿用回退引入时的安全值，
  /// 保证 640×360 不溢出；操作条会折成多行的页面传更大的值。
  final double narrowMinExtent;
  final Widget child;

  static const double _wideMinExtent = 420;
  static const double _widePageWidth = 760;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final threshold = constraints.maxWidth >= _widePageWidth
            ? _wideMinExtent
            : narrowMinExtent;
        if (constraints.maxHeight >= threshold) return child;
        return SingleChildScrollView(
          child: SizedBox(height: narrowMinExtent, child: child),
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
