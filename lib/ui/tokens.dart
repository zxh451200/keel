import 'package:fluent_ui/fluent_ui.dart';

/// 现有 Fluent 界面的公共视觉值；业务控件尺寸仍由页面负责。
abstract final class UiTokens {
  static const pagePadding = EdgeInsets.fromLTRB(32, 28, 32, 28);
  static const panelPadding = EdgeInsets.all(16);
  static const panelHeaderPadding = EdgeInsets.fromLTRB(16, 10, 16, 10);
  static const panelFooterPadding = EdgeInsets.fromLTRB(12, 6, 12, 6);
  static const emptyPadding = EdgeInsets.all(24);
  static const compactPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 6,
  );
  static const panelRadius = BorderRadius.all(Radius.circular(8));
  static const compactRadius = BorderRadius.all(Radius.circular(6));
  static const titleGap = 6.0;
  static const contentGap = 12.0;
  static const sectionGap = 28.0;
  static const dividerThickness = 1.0;

  static UiPalette palette(Brightness brightness) => UiPalette(brightness);
  static UiThemeTokens of(BuildContext context) =>
      UiThemeTokens(FluentTheme.of(context));
}

/// 实色表面与语义色由 brightness 解析，与主题创建共享同一来源。
class UiPalette {
  const UiPalette(this.brightness);

  final Brightness brightness;
  bool get _light => brightness == Brightness.light;

  Color get page => _light ? const Color(0xFFF6F6F6) : const Color(0xFF1F1F1F);
  Color get panel => _light ? const Color(0xFFFFFFFF) : const Color(0xFF2B2B2B);
  Color get menu => _light ? const Color(0xFFFBFBFB) : const Color(0xFF2C2C2C);
  Color get mica => _light ? const Color(0xFFF6F6F6) : const Color(0xFF202020);
  Color get inactive =>
      _light ? const Color(0xFFE5E5E5) : const Color(0xFF3A3A3A);
  Color get shadow =>
      _light ? const Color(0x33000000) : const Color(0x66000000);
  Color get foreground => _light ? Colors.black : Colors.white;
  Color get success =>
      _light ? const Color(0xFF107C10) : const Color(0xFF6CCB5F);
  Color get danger =>
      _light ? const Color(0xFFC42B1C) : const Color(0xFFFF99A4);

  // 填充按钮用较深背景配白字，与用于图标/文字的 danger 分开。
  Color get dangerFill =>
      _light ? const Color(0xFFC42B1C) : const Color(0xFFB3261E);
}

/// 每次 build 解析当前主题，跟随系统/用户的明暗主题切换。
class UiThemeTokens {
  UiThemeTokens(this.theme) : colors = UiTokens.palette(theme.brightness);

  final FluentThemeData theme;
  final UiPalette colors;

  Color get _foreground => theme.typography.body?.color ?? colors.foreground;
  Color get secondaryText => _foreground.withValues(alpha: 0.62);
  Color get emptyText => _foreground.withValues(alpha: 0.55);
  Color get border => _foreground.withValues(alpha: 0.14);
  Color get subtleBorder => _foreground.withValues(alpha: 0.12);
  Color get divider => border;
  Color get accent => theme.accentColor.defaultBrushFor(theme.brightness);
  Color get accentBackground => accent.withValues(alpha: 0.12);
  Color get panelHeaderBackground => accent.withValues(alpha: 0.04);

  TextStyle? get pageTitle => theme.typography.title?.copyWith(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
  );
  TextStyle? get dashboardTitle => theme.typography.title?.copyWith(
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
  );
  TextStyle? get body => theme.typography.body;
  TextStyle? get description => body?.copyWith(color: secondaryText);
  TextStyle? get caption => theme.typography.caption;
  TextStyle? get sectionTitle =>
      theme.typography.bodyStrong?.copyWith(fontSize: 14);
}
