import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/ui/tokens.dart';

/// 页面标题与说明的统一排版；右侧可放主操作。
///
/// 一屏只允许一个主操作：它放在 [actions]，其余操作收进「更多」。
class UiPageHeader extends StatelessWidget {
  const UiPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
  });

  final String title;
  final String? subtitle;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final heading = Column(
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
    if (actions == null) return heading;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: heading),
        const SizedBox(width: UiTokens.gapMd),
        actions!,
      ],
    );
  }
}

/// 内容卡片：可选标题行、主体、可选底栏。
///
/// 卡片靠「一档阴影 + 1px 描边」离开画布，而不是只靠描边；嵌入在其它卡片
/// 里的次级面板可传 `elevated: false` 去掉阴影。
class UiPanel extends StatelessWidget {
  const UiPanel({
    super.key,
    this.header,
    required this.child,
    this.footer,
    this.expand = false,
    this.padding = UiTokens.panelPadding,
    this.elevated = true,
  });

  final Widget? header;
  final Widget child;
  final Widget? footer;
  final bool expand;
  final EdgeInsetsGeometry padding;
  final bool elevated;

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
        boxShadow: elevated ? UiTokens.cardShadow : null,
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

/// 卡片内空状态：图标 + 一句说明 + 可选主操作。
class UiEmpty extends StatelessWidget {
  const UiEmpty({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final content = Padding(
      padding: UiTokens.emptyPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: tokens.panelHeaderBackground,
              shape: BoxShape.circle,
              border: Border.all(color: tokens.subtleBorder),
            ),
            child: Icon(icon, size: 26, color: tokens.emptyText),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: tokens.body?.copyWith(color: tokens.emptyText),
          ),
          if (action != null) ...[
            const SizedBox(height: UiTokens.gapLg),
            action!,
          ],
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

/// 长任务进度条：2px 不确定进度 + 一行说明。
///
/// 说明文字是这块唯一的可读信号，`liveRegion` 让读屏在任务开始时播报一次；
/// 进度条本身只表达「还在跑」。有确定百分比时改传 [value]。
class UiBusyStrip extends StatelessWidget {
  const UiBusyStrip({super.key, required this.message, this.value});

  final String message;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return Semantics(
      liveRegion: true,
      label: message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProgressBar(
            value: value,
            strokeWidth: 2,
            semanticLabel: message,
            activeColor: tokens.accent,
            backgroundColor: tokens.border,
          ),
          const SizedBox(height: UiTokens.gapSm),
          Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tokens.caption?.copyWith(color: tokens.secondaryText),
          ),
        ],
      ),
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

/// 状态胶囊的语义档位；颜色只用于圆点与图标，底色保持中性。
enum UiTone { neutral, accent, success, warning, danger }

/// 状态胶囊：中性底 + 6px 语义圆点，避免「处处彩色」。
class UiStatusPill extends StatelessWidget {
  const UiStatusPill({
    super.key,
    required this.label,
    this.icon,
    this.tone = UiTone.neutral,
  });

  final String label;
  final IconData? icon;
  final UiTone tone;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final colors = tokens.colors;
    final color = switch (tone) {
      UiTone.neutral => tokens.secondaryText,
      UiTone.accent => colors.accent,
      UiTone.success => colors.success,
      UiTone.warning => colors.warning,
      UiTone.danger => colors.danger,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tokens.panelHeaderBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.subtleBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 13, color: color)
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          // 高 DPI 下胶囊在 Wrap 里可能被压窄，文字必须能收缩。
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.caption?.copyWith(color: tokens.secondaryText),
            ),
          ),
        ],
      ),
    );
  }
}

/// 概览数字卡：标签 12、数值 32 等宽、可带一行脚注。
class UiStatCard extends StatelessWidget {
  const UiStatCard({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.tone = UiTone.neutral,
  });

  final String label;
  final String value;
  final String? hint;
  final UiTone tone;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    final colors = tokens.colors;
    final accent = switch (tone) {
      UiTone.neutral => tokens.secondaryText,
      UiTone.accent => colors.accent,
      UiTone.success => colors.success,
      UiTone.warning => colors.warning,
      UiTone.danger => colors.danger,
    };
    return UiPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.caption?.copyWith(color: tokens.secondaryText),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.displayNumber,
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.caption?.copyWith(color: tokens.emptyText),
            ),
          ],
        ],
      ),
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
