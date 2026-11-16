import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/ui/tokens.dart';

/// Fluent 2 主题：Windows 原生观感，三层表面 + 单色强调。
///
/// 显式给出实色，避免 acrylic/mica 在部分窗口合成设置下呈现不一致的底色。
/// 字阶在这里统一收口（22/15/14/12），页面不要再自己写 fontSize；
/// 强调色只用于选中态、主按钮与焦点环。
FluentThemeData keelFluentTheme(Brightness brightness) {
  final colors = UiTokens.palette(brightness);
  final light = brightness == Brightness.light;
  final base = Typography.fromBrightness(
    brightness: brightness,
    color: colors.foreground,
  );
  return FluentThemeData(
    brightness: brightness,
    fontFamily: 'Microsoft YaHei UI',
    accentColor: AccentColor.swatch(
      light
          ? const {
              'normal': Color(0xFF2C5BE0),
              'light': Color(0xFF3A66E8),
              'dark': Color(0xFF2549C4),
              'darker': Color(0xFF1D3AA0),
              'darkest': Color(0xFF162C7C),
            }
          : const {
              'normal': Color(0xFF3D62E8),
              'light': Color(0xFF5578F0),
              'dark': Color(0xFF2F51D0),
              'darker': Color(0xFF25409F),
              'darkest': Color(0xFF1B2F76),
            },
    ),
    // 中文不做负字距；行高统一，缩放时更稳。fontFamily 在 apply 阶段生效。
    typography: Typography.raw(
      display: base.display?.copyWith(letterSpacing: 0),
      titleLarge: base.titleLarge?.copyWith(letterSpacing: 0),
      title: base.title?.copyWith(
        fontSize: 22,
        height: 30 / 22,
        letterSpacing: 0,
      ),
      subtitle: base.subtitle?.copyWith(
        fontSize: 15,
        height: 22 / 15,
        letterSpacing: 0,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 16,
        height: 24 / 16,
        letterSpacing: 0,
      ),
      bodyStrong: base.bodyStrong?.copyWith(
        fontSize: 14,
        height: 22 / 14,
        letterSpacing: 0,
      ),
      body: base.body?.copyWith(
        fontSize: 14,
        height: 22 / 14,
        letterSpacing: 0,
      ),
      caption: base.caption?.copyWith(
        fontSize: 12,
        height: 16 / 12,
        letterSpacing: 0,
      ),
    ),
    scaffoldBackgroundColor: colors.page,
    cardColor: colors.panel,
    menuColor: colors.menu,
    acrylicBackgroundColor: colors.menu,
    acrylicFallbackColor: colors.menu,
    micaBackgroundColor: colors.mica,
    acrylicTintOpacity: 1,
    acrylicLuminosityOpacity: 1,
    inactiveBackgroundColor: colors.inactive,
    shadowColor: colors.shadow,
  );
}
