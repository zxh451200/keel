import 'package:flutter_riverpod/legacy.dart';

/// 左侧导航是否折叠成只显示图标。只影响当前运行，不写入设置。
final navCollapsedProvider = StateProvider<bool>((ref) => false);
