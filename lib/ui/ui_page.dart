import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/l10n/app_localizations.dart';

/// 页面级命令：统一出现在外壳命令栏与“工具”菜单。
/// 快捷键仍由页面自己绑定（避免外壳与页面双触发），这里只做发现提示。
class UiCommand {
  const UiCommand({
    required this.id,
    required this.label,
    this.icon,
    this.shortcutHint,
    required this.onInvoke,
    this.isEnabledProvider,
  });

  final String id;
  final String Function(AppLocalizations) label;
  final IconData? icon;
  final String? shortcutHint;
  final Future<void> Function(BuildContext context, WidgetRef ref) onInvoke;

  /// 命令可用性；未提供时始终可用。
  ///
  /// 外壳在 build 中直接 watch 该 Provider，页面状态（选中项、忙锁、权限）
  /// 变化会重建外壳并刷新命令栏。不要改回在外壳 build 里按需调用的布尔闭包，
  /// 那种形式内部的 watch 不建立订阅，命令会停在旧状态。
  final Provider<bool>? isEnabledProvider;
}

/// 新 Fluent 界面中的页面注册项。
class UiPage {
  const UiPage({
    required this.kind,
    required this.title,
    this.navTitle,
    required this.icon,
    required this.builder,
    this.commands = const [],
  });

  final String kind;
  final String Function(AppLocalizations) title;

  /// 侧栏用的短名称；为空时回退到 [title]。标签页与页面内标题仍用 [title]。
  final String Function(AppLocalizations)? navTitle;
  final IconData icon;
  final Widget Function(BuildContext context, VoidCallback openSelf) builder;

  /// 仅在页面处于活动标签时展示；空表示没有统一命令。
  final List<UiCommand> commands;
}
