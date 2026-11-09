import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef PageCloseGuard = Future<bool> Function();

/// 页面把「能否关闭」注册到外壳；关闭标签前逐个询问。
/// 守卫只检查/确认，不清草稿或释放资源：批量检查的后续页面可能拒绝。
/// 未注册的普通只读页面默认可关闭；内置编辑页须等首帧守卫注册后才能关闭。
class CloseGuards extends Notifier<Map<String, PageCloseGuard>> {
  @override
  Map<String, PageCloseGuard> build() => const {};

  void register(String kind, PageCloseGuard guard) {
    state = {...state, kind: guard};
  }

  void unregister(String kind) {
    if (!state.containsKey(kind)) return;
    state = {...state}..remove(kind);
  }
}

final closeGuardsProvider =
    NotifierProvider<CloseGuards, Map<String, PageCloseGuard>>(CloseGuards.new);
