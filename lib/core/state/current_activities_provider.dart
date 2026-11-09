import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/features/audit/state/audit_export_provider.dart';
import 'package:keel/features/audit/state/audit_print_provider.dart';
import 'package:keel/features/backup/state/backup_providers.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';

/// A live projection of existing busy categories, never a job or history record.
enum CurrentActivity {
  backup('backup'),
  diagnostics('diagnostics'),
  settingsSave('dashboard'),
  auditExport('audit'),
  auditPrint('audit'),
  settingsImport('settings-import'),
  databaseRetry('dashboard');

  const CurrentActivity(this.pageKind);
  final String pageKind;
}

/// Reads activity state only: no operations, history queries or new timers.
final currentActivitiesProvider = Provider<List<CurrentActivity>>((ref) {
  final backup = ref.watch(backupBusyProvider);
  final diagnostics = ref.watch(diagnosticPackBusyProvider);
  final settings = ref.watch(settingsSaveProvider.select((s) => s.saving));
  final audit = ref.watch(auditExportProvider.select((s) => s.busy));
  final printing = ref.watch(auditPrintBusyProvider);
  final importing = ref.watch(
    preferencesImportGateProvider.select((s) => s.busy),
  );
  final retrying = ref.watch(
    databaseRecoveryProvider.select((s) => s.retrying),
  );
  return List<CurrentActivity>.unmodifiable([
    if (backup) CurrentActivity.backup,
    if (diagnostics) CurrentActivity.diagnostics,
    if (settings) CurrentActivity.settingsSave,
    if (audit) CurrentActivity.auditExport,
    if (printing) CurrentActivity.auditPrint,
    if (importing) CurrentActivity.settingsImport,
    if (retrying) CurrentActivity.databaseRetry,
  ]);
});

/// Rechecked at activation and after closing the detail route.
String? currentActivityDestination(
  CurrentActivity activity, {
  required Iterable<CurrentActivity> current,
  required Iterable<String> registeredPages,
}) => current.contains(activity) && registeredPages.contains(activity.pageKind)
    ? activity.pageKind
    : null;
