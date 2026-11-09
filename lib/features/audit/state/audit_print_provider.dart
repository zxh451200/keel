import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/api/desktop_print.dart' as desktop;

typedef AuditPrinter = Future<desktop.DesktopPrintResult> Function(
  String title,
  String content,
);

/// The desktop adapter is replaceable without loading native code in UI tests.
final auditPrinterProvider = Provider<AuditPrinter>(
  (ref) =>
      (title, content) => desktop.printReport(title: title, content: content),
);

/// App-scoped deliberately: hiding or disposing the initiating page must not
/// release native-dialog protection while its asynchronous call is pending.
final auditPrintBusyProvider = StateNotifierProvider<AuditPrintBusy, bool>(
  (ref) => AuditPrintBusy(),
);

class AuditPrintBusy extends StateNotifier<bool> {
  AuditPrintBusy() : super(false);

  Object? _owner;

  Object? acquire() {
    if (_owner != null) return null;
    final owner = Object();
    _owner = owner;
    state = true;
    return owner;
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    if (mounted) state = false;
  }
}
