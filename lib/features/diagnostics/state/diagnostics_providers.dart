import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/src/rust/api/diagnostics.dart';

/// 读取诊断事件的动作。默认调用 Rust；测试里换成假实现。
final diagnosticsSourceProvider =
    Provider<
      Future<List<DiagnosticEvent>> Function(DiagnosticEventQuery query)
    >((ref) => loadDiagnosticEvents);

/// 只保存已提交条件，输入草稿由页面控制器持有；关闭标签即释放。
class DiagnosticsFilter {
  const DiagnosticsFilter({this.minLevel = 'info', this.correlationId = ''});

  final String minLevel;
  final String correlationId;
}

final diagnosticsFilterProvider = StateProvider.autoDispose<DiagnosticsFilter>(
  (ref) => const DiagnosticsFilter(),
);

/// 最近的事件（已脱敏），最新的在前。关闭标签后随页面一起释放。
final diagnosticsEventsProvider =
    FutureProvider.autoDispose<List<DiagnosticEvent>>((ref) {
      ref.watch(databaseEpochProvider);
      final filter = ref.watch(diagnosticsFilterProvider);
      return ref.watch(diagnosticsSourceProvider)(
        DiagnosticEventQuery(
          limit: 200,
          minLevel: filter.minLevel,
          correlationId: filter.correlationId,
        ),
      );
    });

/// 与 Rust str::trim 的 Unicode White_Space 对齐，不剥除 BOM/零宽字符。
String normalizeDiagnosticId(String value) {
  bool space(int rune) =>
      rune >= 0x09 && rune <= 0x0d ||
      rune == 0x20 ||
      rune == 0x85 ||
      rune == 0xa0 ||
      rune == 0x1680 ||
      rune >= 0x2000 && rune <= 0x200a ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202f ||
      rune == 0x205f ||
      rune == 0x3000;
  final runes = value.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && space(runes[start])) {
    start++;
  }
  while (end > start && space(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes.sublist(start, end));
}

bool validDiagnosticId(String value) =>
    value.runes.length <= 128 &&
    !value.runes.any((rune) => rune <= 0x1f || rune >= 0x7f && rune <= 0x9f);

void refreshDiagnostics(WidgetRef ref) {
  if (!ref.read(diagnosticsEventsProvider).isLoading) {
    ref.invalidate(diagnosticsEventsProvider);
  }
}

/// 诊断包的动作：预览将要写入的内容，确认后再导出。默认调用 Rust；测试里换成假实现。
class DiagnosticPackService {
  const DiagnosticPackService({required this.prepare, required this.export});

  final Future<DiagnosticPackPreview> Function(DiagnosticPackRequest) prepare;
  final Future<String> Function(String previewId) export;
}

final diagnosticPackServiceProvider = Provider<DiagnosticPackService>(
  (ref) => const DiagnosticPackService(
    prepare: preparePack,
    export: exportPreparedPack,
  ),
);

/// 关闭控件不代表后台写文件已取消；操作完成前阻止正常系统退出。
class DiagnosticPackActivity extends Notifier<bool> {
  bool _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    return false;
  }

  bool begin() {
    if (_disposed || state) return false;
    state = true;
    return true;
  }

  void finish() {
    if (!_disposed) state = false;
  }
}

final diagnosticPackBusyProvider =
    NotifierProvider<DiagnosticPackActivity, bool>(DiagnosticPackActivity.new);

/// 导出对话框已打开：页面按钮与外壳命令共用，避免叠出第二个导出流程。
class DiagnosticExportGate extends Notifier<bool> {
  @override
  bool build() => false;

  bool begin() {
    if (state) return false;
    state = true;
    return true;
  }

  void finish() => state = false;
}

final diagnosticExportOpenProvider =
    NotifierProvider<DiagnosticExportGate, bool>(DiagnosticExportGate.new);

/// Explicit history requests only; no automatic disk read on opening diagnostics.
final diagnosticHistorySourceProvider =
    Provider<Future<DiagnosticHistoryPage> Function(DiagnosticHistoryQuery)>(
      (ref) => loadDiagnosticHistory,
    );
