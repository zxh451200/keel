import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/ui/tokens.dart';

/// Fluent 2 主题：Windows 原生观感，统一字体、实色背景与蓝色强调色。
///
/// 显式给出实色，避免 acrylic/mica 在部分窗口合成设置下呈现不一致的底色。
FluentThemeData keelFluentTheme(Brightness brightness) {
  final colors = UiTokens.palette(brightness);
  return FluentThemeData(
    brightness: brightness,
    fontFamily: 'Microsoft YaHei UI',
    accentColor: Colors.blue,
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
