import 'package:fluent_ui/fluent_ui.dart';

/// 全站视觉值的唯一来源：间距、圆角、尺寸、阴影、字阶与语义色。
///
/// 命名分三层：
/// - [UiTokens] 与尺寸/间距相关的常量，页面直接引用；
/// - [UiPalette] 由 brightness 解析的实色，主题与控件共享同一来源；
/// - [UiThemeTokens] 每次 build 从当前主题解析的字面样式与语义色。
///
/// 约定：强调色只用于「选中态 / 主按钮 / 键盘焦点环」三处，其余状态走
/// success / warning / danger 语义色，避免到处强调导致没有焦点。
abstract final class UiTokens {
  // 间距阶：4 8 12 16 20 24 32 40。不要引入阶外值。
  static const pagePadding = EdgeInsets.fromLTRB(32, 24, 32, 24);
  static const panelPadding = EdgeInsets.all(16);
  static const panelHeaderPadding = EdgeInsets.fromLTRB(16, 12, 16, 12);
  static const panelFooterPadding = EdgeInsets.fromLTRB(12, 8, 12, 8);
  static const emptyPadding = EdgeInsets.all(28);
  static const compactPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 6,
  );
  static const gapXs = 4.0;
  static const gapSm = 8.0;
  static const gapMd = 12.0;
  static const gapLg = 16.0;
  static const gapXl = 24.0;
  static const gapSection = 32.0;

  static const panelRadius = BorderRadius.all(Radius.circular(10));
  static const compactRadius = BorderRadius.all(Radius.circular(6));
  static const dialogRadius = BorderRadius.all(Radius.circular(12));

  static const titleGap = 4.0;
  static const contentGap = 12.0;
  static const sectionGap = 24.0;
  static const dividerThickness = 1.0;

  // 卡片抬升：卡片靠「一档阴影 + 1px 描边」离开画布，而不是只靠描边。
  static const cardShadow = <BoxShadow>[
    BoxShadow(color: Color(0x0D101828), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A101828), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const popoverShadow = <BoxShadow>[
    BoxShadow(color: Color(0x24101828), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x14101828), blurRadius: 6, offset: Offset(0, 2)),
  ];
  static const dialogShadow = <BoxShadow>[
    BoxShadow(color: Color(0x2E101828), blurRadius: 40, offset: Offset(0, 16)),
  ];

  static UiPalette palette(Brightness brightness) => UiPalette(brightness);
  static UiThemeTokens of(BuildContext context) =>
      UiThemeTokens(FluentTheme.of(context));
}

/// 固定尺寸：外壳与表格共用，避免各处再写魔法数字。
abstract final class UiSize {
  static const titleBar = 40.0;
  static const tabBar = 34.0;
  static const statusBar = 22.0;
  static const navRow = 32.0;
  static const tableRow = 36.0;
  static const sidebar = 240.0;
  static const sidebarCollapsed = 48.0;
  static const controlSm = 28.0;
  static const controlMd = 32.0;
  static const controlLg = 36.0;
  static const iconInline = 16.0;
  static const iconNav = 20.0;
  static const iconEmpty = 40.0;
  static const iconChevron = 12.0;
}

/// 实色表面与语义色由 brightness 解析，与主题创建共享同一来源。
///
/// 层次规则：明度差 > 描边。canvas < chrome < surface，再叠一档阴影；
/// 深色下强调色分两个：文字用 [accent]（要亮），实心按钮底用 [accentFill]（要深）。
class UiPalette {
  const UiPalette(this.brightness);

  final Brightness brightness;
  bool get _light => brightness == Brightness.light;

  /// 页面底
  Color get page => _light ? const Color(0xFFF4F6F9) : const Color(0xFF14161B);

  /// 卡片 / 面板 / 表格
  Color get panel => _light ? const Color(0xFFFFFFFF) : const Color(0xFF1C1F26);

  /// 侧栏、标签条、状态栏
  Color get menu => _light ? const Color(0xFFFBFCFE) : const Color(0xFF1A1D23);

  /// 亚克力回退底色
  Color get mica => _light ? const Color(0xFFF1F3F7) : const Color(0xFF17191F);

  /// 表头、工具栏、脚注、只读区
  Color get sunken =>
      _light ? const Color(0xFFFAFBFC) : const Color(0xFF23272F);

  Color get inactive =>
      _light ? const Color(0xFFEDF0F4) : const Color(0xFF2A2F38);
  Color get shadow =>
      _light ? const Color(0x14101828) : const Color(0x66000000);

  Color get foreground =>
      _light ? const Color(0xFF131720) : const Color(0xFFE8EBF1);
  Color get textSecondary =>
      _light ? const Color(0xFF596273) : const Color(0xFFA2ABBA);
  Color get textTertiary =>
      _light ? const Color(0xFF6B7484) : const Color(0xFF848DA0);

  Color get border =>
      _light ? const Color(0xFFE4E7EC) : const Color(0xFF2E333D);
  Color get borderSubtle =>
      _light ? const Color(0xFFEEF0F4) : const Color(0xFF262A32);
  Color get borderStrong =>
      _light ? const Color(0xFFCDD3DD) : const Color(0xFF3C434F);

  Color get hover => _light ? const Color(0x0A131720) : const Color(0x14FFFFFF);

  Color get accent =>
      _light ? const Color(0xFF2C5BE0) : const Color(0xFF7B95FF);
  Color get accentFill =>
      _light ? const Color(0xFF2C5BE0) : const Color(0xFF3D62E8);
  Color get accentSubtle =>
      _light ? const Color(0xFFEDF1FD) : const Color(0xFF1E2740);

  Color get success =>
      _light ? const Color(0xFF127E43) : const Color(0xFF4ECB8B);
  Color get successSubtle =>
      _light ? const Color(0xFFE8F5EE) : const Color(0xFF16291F);
  Color get warning =>
      _light ? const Color(0xFF9A6300) : const Color(0xFFE0A94A);
  Color get warningSubtle =>
      _light ? const Color(0xFFFFF4E3) : const Color(0xFF2A2116);
  Color get danger =>
      _light ? const Color(0xFFC22B1F) : const Color(0xFFFF8A80);
  Color get dangerSubtle =>
      _light ? const Color(0xFFFDECEA) : const Color(0xFF2C1B1A);

  // 填充按钮用较深背景配白字，与用于图标/文字的 danger 分开。
  Color get dangerFill =>
      _light ? const Color(0xFFC22B1F) : const Color(0xFFB3261E);
}

/// 每次 build 解析当前主题，跟随系统/用户的明暗主题切换。
class UiThemeTokens {
  UiThemeTokens(this.theme) : colors = UiTokens.palette(theme.brightness);

  final FluentThemeData theme;
  final UiPalette colors;

  Color get foreground => colors.foreground;
  Color get secondaryText => colors.textSecondary;
  Color get emptyText => colors.textTertiary;
  Color get border => colors.border;
  Color get subtleBorder => colors.borderSubtle;
  Color get divider => colors.borderSubtle;
  Color get accent => colors.accent;
  Color get accentBackground => colors.accentSubtle;
  Color get panelHeaderBackground => colors.sunken;
  Color get hoverOverlay => colors.hover;

  /// 数字一律等宽：金额、计数、版本、页码、时间切换时宽度不跳动。
  TextStyle? tabular(TextStyle? style) =>
      style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  TextStyle? get pageTitle => theme.typography.title?.copyWith(
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );

  TextStyle? get dashboardTitle => theme.typography.title?.copyWith(
    fontSize: 22,
    height: 30 / 22,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );

  /// 首页 KPI 数值：32/40，等宽。
  TextStyle? get displayNumber => tabular(
    theme.typography.title?.copyWith(
      fontSize: 32,
      height: 40 / 32,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
  );

  TextStyle? get subtitle => theme.typography.body?.copyWith(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w600,
    color: colors.foreground,
  );

  TextStyle? get body => theme.typography.body;
  TextStyle? get bodyStrong => theme.typography.bodyStrong;

  TextStyle? get description => body?.copyWith(color: secondaryText);

  /// 13/20：次要正文、表头、标签条。
  TextStyle? get small => body?.copyWith(fontSize: 13, height: 20 / 13);

  TextStyle? get caption => theme.typography.caption;
  TextStyle? get sectionTitle =>
      theme.typography.bodyStrong?.copyWith(fontSize: 14, height: 22 / 14);

  TextStyle? get tableHeader => theme.typography.caption?.copyWith(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w600,
    color: secondaryText,
  );
}
