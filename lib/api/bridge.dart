// 手写桥接适配层：所有对 Rust 的调用都从这里出去（AGENTS.md §3、§4）。
// `lib/src/rust/` 由 `flutter_rust_bridge_codegen generate` 生成，不手改。
//
// 副作用（FFI 调用）只留在这一层，展示层因此可以在不带 Rust 动态库的
// `flutter test` 环境下用假实现验证。后续的错误映射、DTO 转出也放在这里。

import 'dart:typed_data';

import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/audit.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/audit_export_history.dart'
    as rust_audit_export_history;
import 'package:keel/src/rust/api/backup.dart';
import 'package:keel/src/rust/api/customers.dart';
import 'package:keel/src/rust/api/diagnostics.dart';
import 'package:keel/src/rust/api/grid_preferences.dart'
    as rust_grid_preferences;
import 'package:keel/src/rust/api/ping.dart';
import 'package:keel/src/rust/api/settings.dart'
    hide WorkspaceNavigationPreferences;
import 'package:keel/src/rust/api/settings.dart'
    as rust_settings
    show WorkspaceNavigationPreferences;
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart'
    as navigation;
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/src/rust/api/simple.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' as frb;
import 'package:keel/src/rust/frb_generated.dart';

/// 启动结果：用户设置，以及这次运行能不能把设置写回文件。
class BridgeInit {
  const BridgeInit({
    required this.settings,
    required this.canSave,
    required this.navigationPreferences,
    this.databaseError,
    this.settingsError,
    this.navigationError,
    this.regionalSettings,
  });

  final Settings settings;
  final RegionalSettings? regionalSettings;
  final bool canSave;
  final navigation.WorkspaceNavigationPreferences navigationPreferences;
  final Object? databaseError;
  final Object? settingsError;
  final Object? navigationError;
}

/// 启动时调用一次：加载 Rust 动态库，读取用户设置。
///
/// 配置文件损坏或来自更新版本时用默认设置启动，并且本次运行不写回，
/// 避免覆盖用户原来的文件。
Future<BridgeInit> initBridge() async {
  await RustLib.init();
  // 数据库打开失败不阻止应用启动：错误已写入日志和诊断中心，
  // 状态栏会显示数据库不可用，依赖数据库的页面各自显示错误。
  Object? databaseError;
  try {
    await initDatabase();
  } catch (error) {
    databaseError = error;
  }
  return loadBridgePreferences(databaseError: databaseError);
}

/// 分开读取两个 DTO，但共享配置保护结论；参数用于无动态库的启动回归测试。
Future<BridgeInit> loadBridgePreferences({
  Object? databaseError,
  Future<Settings> Function()? settingsSource,
  Future<navigation.WorkspaceNavigationPreferences> Function()?
  navigationSource,
  Future<RegionalSettings> Function()? regionalSource,
}) async {
  var settings = Settings(language: null, theme: null, formatLocale: null);
  var preferences = navigation.WorkspaceNavigationPreferences();
  Object? settingsError;
  Object? navigationError;
  Object? regionalError;
  var regional = RegionalSettings(timeZone: null, currency: null);
  try {
    settings = await (settingsSource ?? loadSettings)();
  } catch (error) {
    settingsError = error;
  }
  try {
    preferences = await (navigationSource ?? loadWorkspaceNavigationFromRust)();
  } catch (error) {
    navigationError = error;
  }
  try {
    regional = await (regionalSource ?? loadRegionalSettingsFromRust)();
  } catch (error) {
    regionalError = error;
  }
  return BridgeInit(
    settings: settings,
    regionalSettings: regional,
    navigationPreferences: preferences,
    canSave:
        settingsError == null &&
        navigationError == null &&
        regionalError == null,
    settingsError: settingsError ?? regionalError,
    navigationError: navigationError,
    databaseError: databaseError,
  );
}

/// 数据库失败后重试，Rust 端负责串行初始化；不要求重启应用。
Future<void> retryDatabaseInitialization() => initDatabase();

/// 异步保存设置与待写审计；数据库不可用时由 Rust 保留队列，恢复后补写。
Future<void> saveSettingsToRust(Settings settings) =>
    saveSettings(settings: settings);

Future<Settings> loadSettingsFromRust() async => loadSettings();

Future<RegionalSettings> loadRegionalSettingsFromRust() async =>
    loadRegionalSettings();

Future<void> saveRegionalSettingsToRust(RegionalSettings settings) =>
    saveRegionalSettings(settings: settings);

Future<ExternalConfigPreview> prepareSettingsImport(Uint8List input) async =>
    prepareExternalConfig(input: input);

Future<ExternalConfigPreview> prepareSettingsFileImport(String path) async =>
    prepareExternalConfigFile(path: path);

Future<void> confirmSettingsImport(String previewId) =>
    importPreparedExternalConfig(previewId: previewId);

Future<navigation.WorkspaceNavigationPreferences>
loadWorkspaceNavigationFromRust() async {
  final preferences = await loadWorkspaceNavigationPreferences();
  return navigation.WorkspaceNavigationPreferences(
    recentKinds: preferences.recentKinds,
    favoriteKinds: preferences.favoriteKinds,
    navCollapsed: preferences.navCollapsed,
  );
}

Future<void> saveWorkspaceNavigationToRust(
  navigation.WorkspaceNavigationPreferences preferences,
) => saveWorkspaceNavigationPreferences(
  preferences: rust_settings.WorkspaceNavigationPreferences(
    recentKinds: preferences.recentKinds,
    favoriteKinds: preferences.favoriteKinds,
    navCollapsed: preferences.navCollapsed,
  ),
);

/// 阶段 0 桥接样例的三类调用：同步字符串、同步结构体、异步结构体。
String samplesGreet() => greet(name: 'Tom');

PingResponse samplesSyncPing() => ping(
  request: PingRequest(
    sequence: 1,
    payload: 'keel-sync',
    tags: const ['bridge', 'stage-0'],
  ),
);

Future<PingResponse> samplesAsyncPing(PingRequest request) =>
    pingAsync(request: request);

/// 诊断中心用：读取最近的诊断事件（已脱敏），最新的在前。
Future<List<DiagnosticEvent>> loadDiagnosticEvents(
  DiagnosticEventQuery query,
) => recentEvents(query: query);

/// 状态栏用：程序版本和数据库是否就绪。
Future<AppStatus> loadAppStatus() async => appStatus();

/// 本次启动的恢复结论不随数据库重试清除，不包含文件路径或原始错误。
Future<StartupRestoreStatus> loadStartupRestoreStatus() async =>
    startupRestoreStatus();

/// 审计日志列表用：取一页。
Future<AuditPage> loadAuditPage(AuditQuery query) =>
    listAuditLogs(query: query);

Future<AuditExportStatus> beginAuditCsvExport(AuditQuery query) =>
    startAuditExport(query: query);

// Requires FRB regeneration for list_audit_exports; never hand-edit generated code.
Future<List<AuditExportStatus>> listAuditCsvExports() => listAuditExports();

/// 持久历史只返回脱敏元数据；该模块由 FRB 正常生成。
Future<rust_audit_export_history.AuditExportHistoryPage>
listAuditExportHistory({required int page, required int pageSize}) =>
    rust_audit_export_history.listAuditExportHistory(
      page: page,
      pageSize: pageSize,
    );

Future<AuditExportStatus> readAuditCsvExport(String taskId) =>
    auditExportStatus(taskId: taskId);

Future<AuditExportStatus> cancelAuditCsvExport(String taskId) =>
    cancelAuditExport(taskId: taskId);

Future<String> saveAuditCsvCopy(String taskId, String destination) =>
    saveAuditExportCopy(taskId: taskId, destination: destination);

/// 用户相关：当前用户、用户列表、创建、切换。
Future<UserInfo> loadCurrentUser() => currentUser();

Future<List<UserInfo>> loadUsers() => listUsers();

Future<String> prepareLocalUserImport() => prepareUserImport();

Future<int> runLocalUserImport(String ticket, Uint8List input) =>
    runUserImport(ticketId: ticket, input: input);

Future<void> cancelLocalUserImport(String ticket) async =>
    cancelUserImport(ticketId: ticket);

Future<({int processed, int total})?> readLocalUserImportProgress(
  String ticket,
) async {
  final value = await userImportProgress(ticketId: ticket);
  return value == null
      ? null
      : (processed: value.processed, total: value.total);
}

Future<void> createLocalUser(String name, String role) =>
    createUser(name: name, role: role);

Future<UserInfo> switchLocalUser(String name) => switchUser(name: name);

/// 备份与恢复。界面只用备份的名字，不传路径。
Future<List<BackupInfo>> loadBackups() => listBackups();

Future<BackupInfo> createBackupNow() => createBackup();

Future<void> scheduleRestoreOf(String name) => scheduleRestore(name: name);

Future<void> cancelPendingRestore() => cancelScheduledRestore();

Future<String?> loadPendingRestore() => pendingRestore();

/// 按类别准备已脱敏快照，确认后以相同快照标识导出。
Future<DiagnosticPackPreview> preparePack(DiagnosticPackRequest request) =>
    prepareDiagnosticPack(request: request);

Future<String> exportPreparedPack(String previewId) =>
    exportPreparedDiagnosticPack(previewId: previewId);

Future<ExternalDiagnosticPreview> prepareExternalDiagnosticTextFromRust(
  String text,
) => prepareExternalDiagnosticText(text: text);

Future<ExternalDiagnosticPreview> prepareExternalDiagnosticFileFromRust(
  String path,
) => prepareExternalDiagnosticFile(path: path);

Future<rust_grid_preferences.GridPreferences> loadGridPreferencesFromRust(
  String listId,
) => rust_grid_preferences.loadGridPreferences(listId: listId);

Future<rust_grid_preferences.GridPreferences> saveGridPreferencesToRust(
  rust_grid_preferences.SaveGridPreferences request,
) => rust_grid_preferences.saveGridPreferences(request: request);

/// Independent history API: no filesystem paths cross this boundary.
Future<DiagnosticHistoryPage> loadDiagnosticHistory(
  DiagnosticHistoryQuery query,
) => searchDiagnosticHistory(query: query);

// 往来单位（参考实体）：列表只读，维护需要 customers.manage（Rust 边界再校验）。
Future<CustomerPage> loadCustomers(CustomerQuery query) =>
    listCustomers(query: query);

Future<int> createCustomerInRust(SaveCustomerRequest request) async =>
    await createCustomer(request: request);

Future<void> updateCustomerInRust(int id, SaveCustomerRequest request) =>
    updateCustomer(id: id, request: request);

Future<int> deleteCustomersInRust(List<int> ids) async =>
    await deleteCustomers(ids: frb.Int64List.fromList(ids));

Future<int> setCustomersActiveInRust(List<int> ids, bool active) async =>
    await setCustomersActive(ids: frb.Int64List.fromList(ids), active: active);

// 登录门禁：口令只发给 Rust 校验，桥接层不保存、不回显。
Future<AuthStatusDto> loadAuthStatus() => authStatus();

/// 失败时多等 250ms，降低界面上的连续试错速度。
Future<bool> signInWithPassword(String password) async {
  final ok = await signIn(password: password);
  if (!ok) await Future<void>.delayed(const Duration(milliseconds: 250));
  return ok;
}

Future<void> lockApplication() => lockApp();

Future<void> setLoginPasswordInRust(String? current, String next) =>
    setLoginPassword(currentPassword: current, newPassword: next);

Future<void> setLoginRequiredInRust(bool enabled, String password) =>
    setLoginRequired(enabled: enabled, password: password);
