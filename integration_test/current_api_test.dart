// Real FRB + SQLite coverage. Run through scripts/verify.ps1, which provides
// a fresh KEEL_DATA_DIR before starting the desktop process and cleans it only
// after that process exits. Never initialize Rust before the isolation guard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/src/rust/api/app.dart' as app;
import 'package:keel/src/rust/api/audit.dart' as audit;
import 'package:keel/src/rust/api/backup.dart' as backup;
import 'package:keel/src/rust/api/customers.dart' as customers;
import 'package:keel/src/rust/api/diagnostics.dart' as diagnostics;
import 'package:keel/src/rust/api/error.dart';
import 'package:keel/src/rust/api/settings.dart' as settings;
import 'package:keel/src/rust/api/users.dart' as users;
import 'package:keel/src/rust/frb_generated.dart';

Future<Directory> _requireIsolation() async {
  final path = Platform.environment['KEEL_DATA_DIR'];
  final token = Platform.environment['KEEL_FRB_TEST_TOKEN'];
  if (path == null ||
      token == null ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(token) ||
      !Directory(path).isAbsolute) {
    throw StateError('Run through scripts/verify.ps1 with a fresh test root.');
  }
  final root = Directory(path);
  final expected = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}keel-frb-$token',
  );
  if (root.absolute.uri != expected.absolute.uri ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Unexpected integration data root.');
  }
  final entries = await root.list(followLinks: false).toList();
  final marker = File('${root.path}/.keel-frb-test-owner');
  if (entries.length != 1 ||
      await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await marker.readAsString() != token) {
    throw StateError('Test root must contain only its ownership marker.');
  }
  return root;
}

Future<ApiError> _error(
  FutureOr<dynamic> Function() operation,
  String code,
) async {
  try {
    await operation();
  } on ApiError catch (error) {
    expect(error.code, code);
    expect(error.correlationId, isNotEmpty);
    return error;
  }
  throw TestFailure('Expected public ApiError $code.');
}

Map<String, dynamic> _configWithoutImportAudit(List<int> bytes) =>
    (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
      ..remove('pending_settings_import_audit');

Future<void> _failedImport(
  File config,
  FutureOr<dynamic> Function() operation,
  String code,
  String actor,
) async {
  final before = _configWithoutImportAudit(await config.readAsBytes());
  final history = await audit.listAuditLogs(
    query: _query(keyword: 'settings.import', descending: true),
  );
  await _error(operation, code);
  final persisted = await config.readAsBytes();
  // Failure may append a durable import event and rewrite the JSON. With this
  // fixture's initialized, healthy DB it must flush, leaving preferences intact.
  expect(_configWithoutImportAudit(persisted), before);
  expect(
    ((jsonDecode(utf8.decode(persisted))
                as Map)['pending_settings_import_audit']
            as List?) ??
        const [],
    isEmpty,
  );
  final after = await audit.listAuditLogs(
    query: _query(keyword: 'settings.import', descending: true),
  );
  expect(after.total, history.total + 1);
  final added = after.items
      .where((item) => !history.items.any((previous) => previous.id == item.id))
      .toList();
  expect(added, hasLength(1));
  expect(added.single.actor, actor);
  expect(added.single.action, 'settings.import');
  expect(added.single.target, 'application');
  expect(added.single.result, 'failed:$code');
}

Uint8List _external({String locale = 'zh_CN'}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'version': 4,
      'language': 'zh',
      'theme': 'light',
      'format_locale': locale,
      'pending_settings_audit': <Object>[],
      'workspace_navigation': {
        'recent_kinds': ['diagnostics', 'audit'],
        'favorite_kinds': ['audit'],
        'nav_collapsed': true,
      },
    }),
  ),
);

audit.AuditQuery _query({
  String keyword = '',
  int? startAtMs,
  int? endAtMsExclusive,
  int page = 1,
  int size = 200,
  String sort = 'at',
  bool descending = false,
}) => audit.AuditQuery(
  keyword: keyword,
  startAtMs: startAtMs,
  endAtMsExclusive: endAtMsExclusive,
  sort: [audit.AuditSort(field: sort, descending: descending)],
  page: page,
  pageSize: size,
);

// One monotonic deadline per export test, including each pending FFI call.
// A slow/hung status call must not turn a bounded poll into an infinite wait.
Future<T> _exportStep<T>(Stopwatch clock, Future<T> Function() operation) {
  final remaining = const Duration(seconds: 45) - clock.elapsed;
  if (remaining <= Duration.zero) {
    throw TestFailure('Audit export did not finish within the test deadline.');
  }
  return operation().timeout(remaining);
}

Future<audit.AuditExportStatus> _exportTerminal(
  Stopwatch clock,
  audit.AuditExportStatus status,
) async {
  final taskId = status.taskId;
  var previousRows = status.completedRows;
  while (true) {
    expect(status.taskId, taskId);
    expect(status.phase, isIn(['running', 'completed', 'cancelled', 'failed']));
    expect(status.completedRows, greaterThanOrEqualTo(previousRows));
    expect(status.completedRows, lessThanOrEqualTo(status.totalRows));
    if (status.phase != 'running') return status;
    expect(status.outputPath, isNull);
    previousRows = status.completedRows;
    await _exportStep(
      clock,
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    status = await _exportStep(
      clock,
      () => audit.auditExportStatus(taskId: taskId),
    );
  }
}

Future<File> _exportFile(Directory root, audit.AuditExportStatus status) async {
  expect(status.phase, 'completed');
  expect(status.errorCode, isNull);
  expect(status.completedRows, status.totalRows);
  expect(status.outputPath, isNotNull);
  final file = File(status.outputPath!);
  expect(
    file.absolute.uri,
    File('${root.path}/exports/audit-${status.taskId}.csv').absolute.uri,
  );
  expect(
    await FileSystemEntity.type(file.path, followLinks: false),
    FileSystemEntityType.file,
  );
  final canonicalRoot = await root.resolveSymbolicLinks();
  expect(
    Directory(await file.parent.resolveSymbolicLinks()).uri,
    Directory('$canonicalRoot/exports').uri,
  );
  return file;
}

Future<Set<String>> _exportEntries(Directory root) async {
  final directory = Directory('${root.path}/exports');
  if (!await directory.exists()) return <String>{};
  return directory
      .list(followLinks: false)
      .map((entry) => entry.absolute.uri.toString())
      .toSet();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File config;
  late String admin;

  setUpAll(() async {
    root = await _requireIsolation();
    config = File('${root.path}/config.json');
    await RustLib.init();
    expect(app.appStatus().databaseReady, isFalse);
    expect(app.startupRestoreStatus().outcome, 'none');
    await _error(() => users.currentUser(), 'KEEL-UNINITIALIZED');
    final defaults = await settings.loadSettings();
    expect(defaults.language, isNull);
    expect(defaults.theme, isNull);
    expect(defaults.formatLocale, isNull);
    // Exercise concurrent initialization through the bridge, not service calls.
    await Future.wait([app.initDatabase(), app.initDatabase()]);
    expect(app.appStatus().databaseReady, isTrue);
    expect(app.appStatus().version, isNotEmpty);
    expect(await File('${root.path}/keel.db').exists(), isTrue);
    final restore = app.startupRestoreStatus();
    expect(restore.outcome, 'none');
    expect(restore.errorCode, isNull);
    expect(restore.correlationId, isNull);
    final me = await users.currentUser();
    admin = me.name;
    expect(me.role, 'admin');
    await users.createUser(name: 'frb-viewer', role: 'viewer');
    await users.createUser(name: 'frb-operator', role: 'operator');
    await users.createUser(name: 'frb-other-admin', role: 'admin');
  });

  setUp(() async {
    audit.resetAuditExportRegistryForTests();
    await users.switchUser(name: admin);
    await settings.saveSettings(
      settings: settings.Settings(
        language: 'en',
        theme: 'dark',
        formatLocale: 'en_GB',
      ),
    );
  });

  testWidgets('startup retries are idempotent and preserve current identity', (
    tester,
  ) async {
    final before = await audit.listAuditLogs(
      query: _query(keyword: 'app.start'),
    );
    expect(before.total, 1);
    await users.switchUser(name: 'frb-operator');
    await app.initDatabase();
    expect((await users.currentUser()).name, 'frb-operator');
    expect(app.appStatus().databaseReady, isTrue);
    expect(app.startupRestoreStatus().outcome, 'none');
    final after = await audit.listAuditLogs(
      query: _query(keyword: 'app.start'),
    );
    expect(after.total, before.total);
  });

  testWidgets(
    'settings v4 locale and navigation round trip without lost fields',
    (tester) async {
      await settings.saveWorkspaceNavigationPreferences(
        preferences: settings.WorkspaceNavigationPreferences(
          recentKinds: ['users', 'audit'],
          favoriteKinds: ['audit'],
          navCollapsed: true,
        ),
      );
      for (final locale in <String?>['en_US', 'zh_CN', 'en_GB', null]) {
        await settings.saveSettings(
          settings: settings.Settings(
            language: 'en',
            theme: 'light',
            formatLocale: locale,
          ),
        );
        final loaded = await settings.loadSettings();
        expect(loaded.language, 'en');
        expect(loaded.theme, 'light');
        expect(loaded.formatLocale, locale);
        final navigation = await settings.loadWorkspaceNavigationPreferences();
        expect(navigation.recentKinds, ['users', 'audit']);
        expect(navigation.favoriteKinds, ['audit']);
        expect(navigation.navCollapsed, isTrue);
        final persisted = jsonDecode(await config.readAsString()) as Map;
        // 配置 v5 新增独立 time_zone/currency，保存按当前版本写回。
        expect(persisted['version'], 5);
        expect(persisted['format_locale'], locale);
      }
      final before = await config.readAsBytes();
      await _error(
        () => settings.saveSettings(
          settings: settings.Settings(
            language: 'en',
            theme: 'dark',
            formatLocale: 'en-US',
          ),
        ),
        'KEEL-VALIDATION',
      );
      expect(await config.readAsBytes(), before);
      await _error(
        () => settings.saveWorkspaceNavigationPreferences(
          preferences: settings.WorkspaceNavigationPreferences(
            recentKinds: ['bad/path'],
            favoriteKinds: [],
            navCollapsed: false,
          ),
        ),
        'KEEL-VALIDATION',
      );
      expect(await config.readAsBytes(), before);
      final events = await audit.listAuditLogs(
        query: _query(keyword: 'settings.change'),
      );
      expect(
        events.items.any((item) => item.result.contains('format_locale')),
        isTrue,
      );
    },
  );

  testWidgets('prepare-confirm imports v4 once and rejects unsafe inputs', (
    tester,
  ) async {
    final before = await config.readAsBytes();
    final preview = await settings.prepareExternalConfig(input: _external());
    expect(preview.previewId, isNotEmpty);
    expect(preview.configVersion, 4);
    expect(preview.preview, isNotEmpty);
    expect(await config.readAsBytes(), before);
    await settings.importPreparedExternalConfig(previewId: preview.previewId);
    final loaded = await settings.loadSettings();
    expect(loaded.language, 'zh');
    expect(loaded.theme, 'light');
    expect(loaded.formatLocale, 'zh_CN');
    final navigation = await settings.loadWorkspaceNavigationPreferences();
    expect(navigation.recentKinds, ['diagnostics', 'audit']);
    expect(navigation.favoriteKinds, ['audit']);
    expect(navigation.navCollapsed, isTrue);
    await _failedImport(
      config,
      () => settings.importPreparedExternalConfig(previewId: preview.previewId),
      'KEEL-IMPORT',
      admin,
    );
    await _failedImport(
      config,
      () => settings.importPreparedExternalConfig(previewId: 'unknown-preview'),
      'KEEL-IMPORT',
      admin,
    );
    final saved = await config.readAsBytes();
    for (final (input, code) in [
      (utf8.encode('not json'), 'KEEL-IMPORT'),
      (utf8.encode('{ broken'), 'KEEL-VALIDATION'),
      (utf8.encode('{"version":99}'), 'KEEL-VALIDATION'),
      (utf8.encode('{"version":4,"command":"run"}'), 'KEEL-IMPORT'),
      (<int>[0xff, 0xfe], 'KEEL-VALIDATION'),
      (List<int>.filled(1024 * 1024 + 1, 32), 'KEEL-VALIDATION'),
    ]) {
      await _error(
        () => settings.prepareExternalConfig(input: Uint8List.fromList(input)),
        code,
      );
      expect(await config.readAsBytes(), saved);
    }
    final imported = await audit.listAuditLogs(
      query: _query(keyword: 'settings.import'),
    );
    expect(
      imported.items.any((item) => item.actor == admin && item.result == 'ok'),
      isTrue,
    );
    expect(
      imported.items.any((item) => item.result == 'failed:KEEL-IMPORT'),
      isTrue,
    );
  });

  testWidgets(
    'failed confirm protects damaged target and consumes the handle',
    (tester) async {
      final saved = await config.readAsBytes();
      final preview = await settings.prepareExternalConfig(input: _external());
      try {
        // Fault injection is confined to this run's config; all application
        // operations still cross the public FRB boundary.
        await config.writeAsString('{ broken target', flush: true);
        await _error(
          () => settings.importPreparedExternalConfig(
            previewId: preview.previewId,
          ),
          'KEEL-VALIDATION',
        );
        expect(await config.readAsString(), '{ broken target');
        await _error(() => settings.loadSettings(), 'KEEL-VALIDATION');
      } finally {
        await config.writeAsBytes(saved, flush: true);
      }
      await _failedImport(
        config,
        () =>
            settings.importPreparedExternalConfig(previewId: preview.previewId),
        'KEEL-IMPORT',
        admin,
      );
    },
  );

  testWidgets(
    'file prepare confirms its snapshot after source replacement or deletion',
    (tester) async {
      final source = File('${root.path}/frb-snapshot-source.json');
      for (final deleteSource in [false, true]) {
        // A distinct locale in each pass proves the second confirm also writes
        // its prepared snapshot rather than merely leaving the last import.
        final locale = deleteSource ? 'en_US' : 'zh_CN';
        final original = _external(locale: locale);
        await source.writeAsBytes(original, flush: true);
        final before = await config.readAsBytes();
        final preview = await settings.prepareExternalConfigFile(
          path: source.path,
        );
        expect(preview.previewId, isNotEmpty);
        expect(preview.configVersion, 4);
        expect(preview.preview, isNotEmpty);
        expect(await config.readAsBytes(), before);
        expect(await source.readAsBytes(), original);
        if (deleteSource) {
          await source.delete();
        } else {
          // Valid replacement with different values, not an artificial read
          // failure: confirm must import the earlier bytes in either case.
          await source.writeAsString(
            '{"version":4,"language":"en","theme":"dark","format_locale":"en_GB"}',
            flush: true,
          );
        }
        await settings.importPreparedExternalConfig(
          previewId: preview.previewId,
        );
        final loaded = await settings.loadSettings();
        expect(loaded.language, 'zh');
        expect(loaded.theme, 'light');
        expect(loaded.formatLocale, locale);
        final navigation = await settings.loadWorkspaceNavigationPreferences();
        expect(navigation.recentKinds, ['diagnostics', 'audit']);
        expect(navigation.favoriteKinds, ['audit']);
        expect(navigation.navCollapsed, isTrue);
        if (deleteSource) {
          expect(await source.exists(), isFalse);
        } else {
          expect(await source.readAsString(), contains('"language":"en"'));
        }
        await _failedImport(
          config,
          () => settings.importPreparedExternalConfig(
            previewId: preview.previewId,
          ),
          'KEEL-IMPORT',
          admin,
        );
      }
    },
  );

  testWidgets('file prepare rejects permission before inspecting the source', (
    tester,
  ) async {
    final source = File('${root.path}/frb-permission-source.json');
    final bytes = _external();
    await source.writeAsBytes(bytes, flush: true);
    final before = await config.readAsBytes();
    await users.switchUser(name: 'frb-viewer');
    try {
      await _error(
        () => settings.prepareExternalConfigFile(path: source.path),
        'KEEL-PERMISSION',
      );
      expect(await source.readAsBytes(), bytes);
      await source.delete();
      // Missing source would produce KEEL-IMPORT if file inspection ran first.
      await _error(
        () => settings.prepareExternalConfigFile(path: source.path),
        'KEEL-PERMISSION',
      );
      expect(await config.readAsBytes(), before);
      expect(await source.exists(), isFalse);
    } finally {
      await users.switchUser(name: admin);
    }
    await _error(
      () => settings.prepareExternalConfigFile(path: source.path),
      'KEEL-IMPORT',
    );
    expect(await config.readAsBytes(), before);
  });

  testWidgets('switching users enforces permissions and preview ownership', (
    tester,
  ) async {
    final names = (await users.listUsers()).map((user) => user.name);
    expect(names, containsAll([admin, 'frb-viewer', 'frb-operator']));
    await _error(
      () => users.createUser(name: 'frb-viewer', role: 'viewer'),
      'KEEL-DUPLICATE',
    );
    await _error(
      () => users.switchUser(name: 'frb-missing-user'),
      'KEEL-NOT-FOUND',
    );
    expect((await users.currentUser()).name, admin);
    final preview = await settings.prepareExternalConfig(input: _external());
    final before = _configWithoutImportAudit(await config.readAsBytes());
    final viewer = await users.switchUser(name: 'frb-viewer');
    expect(viewer.permissions, ['audit.read']);
    expect((await users.currentUser()).role, 'viewer');
    await audit.listAuditLogs(query: _query());
    await _error(
      () => users.createUser(name: 'frb-forbidden', role: 'admin'),
      'KEEL-PERMISSION',
    );
    await _error(() => backup.createBackup(), 'KEEL-PERMISSION');
    await _error(() => backup.cancelScheduledRestore(), 'KEEL-PERMISSION');
    await _error(
      () => settings.prepareExternalConfig(input: _external()),
      'KEEL-PERMISSION',
    );
    await _failedImport(
      config,
      () => settings.importPreparedExternalConfig(previewId: preview.previewId),
      'KEEL-PERMISSION',
      'frb-viewer',
    );
    await _error(
      () => diagnostics.prepareDiagnosticPack(
        request: diagnostics.DiagnosticPackRequest(categories: ['runtime']),
      ),
      'KEEL-PERMISSION',
    );
    // Another admin has permission, but cannot consume someone else's preview.
    await users.switchUser(name: 'frb-other-admin');
    await _failedImport(
      config,
      () => settings.importPreparedExternalConfig(previewId: preview.previewId),
      'KEEL-PERMISSION',
      'frb-other-admin',
    );
    expect(_configWithoutImportAudit(await config.readAsBytes()), before);
    await users.switchUser(name: admin);
    await settings.importPreparedExternalConfig(previewId: preview.previewId);
    final operator = await users.switchUser(name: 'frb-operator');
    expect(operator.permissions, contains('settings.import'));
    expect(operator.permissions, isNot(contains('backup.restore')));
    await _error(() => backup.cancelScheduledRestore(), 'KEEL-PERMISSION');
    expect(
      (await users.listUsers()).any((user) => user.name == 'frb-forbidden'),
      isFalse,
    );
  });

  testWidgets(
    'audit filtering, ordering, pagination and validation use real rows',
    (tester) async {
      for (final suffix in ['c', 'a', 'b']) {
        await users.createUser(name: 'frb-page-$suffix', role: 'viewer');
      }
      final all = await audit.listAuditLogs(
        query: _query(keyword: 'frb-page-'),
      );
      expect(all.total, 3);
      expect(all.items.length, 3);
      final first = await audit.listAuditLogs(
        query: _query(keyword: 'frb-page-', size: 2),
      );
      final second = await audit.listAuditLogs(
        query: _query(keyword: 'frb-page-', page: 2, size: 2),
      );
      expect(first.total, all.total);
      expect(second.total, all.total);
      expect(first.items.length, 2);
      expect(second.items.length, 1);
      expect(
        [...first.items, ...second.items].map((item) => item.id).toList(),
        all.items.map((item) => item.id).toList(),
      );
      final reverse = await audit.listAuditLogs(
        query: _query(keyword: 'frb-page-', descending: true),
      );
      expect(
        reverse.items.map((item) => item.id).toList(),
        all.items.reversed.map((item) => item.id).toList(),
      );
      final empty = await audit.listAuditLogs(
        query: _query(keyword: 'frb-page-', page: 3, size: 2),
      );
      expect(empty.items, isEmpty);
      expect(empty.total, all.total);
      for (final query in [
        _query(page: 0),
        _query(size: 0),
        _query(size: 201),
        _query(sort: 'at; DROP TABLE audit_log'),
      ]) {
        await _error(
          () => audit.listAuditLogs(query: query),
          'KEEL-VALIDATION',
        );
      }
      expect(
        (await audit.listAuditLogs(query: _query(keyword: 'frb-page-'))).total,
        all.total,
      );
    },
  );

  testWidgets(
    'audit CSV exports all filtered rows with quoting and formula protection',
    (tester) async {
      final clock = Stopwatch()..start();
      // Create the rows exclusively through the public user API. The first
      // target exercises a formula prefix, comma, quote and UTF-8 in one cell.
      final targets = {
        '=frb-csv-%_,"中': "\"'=frb-csv-%_,\"\"中\"",
        'frb-csv-%_-b': '"frb-csv-%_-b"',
      };
      for (final name in [...targets.keys, 'frb-csv-xx-b']) {
        await _exportStep(
          clock,
          () => users.createUser(name: name, role: 'viewer'),
        );
      }
      final rows = await _exportStep(
        clock,
        () => audit.listAuditLogs(
          query: _query(keyword: 'frb-csv-%_', descending: true),
        ),
      );
      expect(rows.total, 2);
      expect(
        rows.items.map((item) => item.target).toSet(),
        targets.keys.toSet(),
      );
      final started = await _exportStep(
        clock,
        () => audit.startAuditExport(
          // Deliberately request page 2 of size 1: export must still include both
          // rows, with % and _ interpreted literally and the decoy excluded.
          query: _query(
            keyword: 'frb-csv-%_',
            page: 2,
            size: 1,
            descending: true,
          ),
        ),
      );
      final done = await _exportTerminal(clock, started);
      expect(done.totalRows, 2);
      final file = await _exportStep(clock, () => _exportFile(root, done));
      final expected = StringBuffer(
        '\ufeffid,at_utc_ms,actor,action,target,result\r\n',
      );
      for (final row in rows.items) {
        expect(row.actor, admin);
        expect(row.action, 'user.create');
        expect(row.result, 'ok');
        expected.write(
          '"${row.id}","${row.at}","$admin","user.create",'
          '${targets[row.target]},"ok"\r\n',
        );
      }
      final bytes = await _exportStep(clock, () => file.readAsBytes());
      // Compare the entire file, including BOM, column order, escaped cells,
      // stable row order, CRLF and the absence of unrelated audit entries.
      expect(bytes, utf8.encode(expected.toString()));
      final cancelledAfterPublish = await _exportStep(
        clock,
        () => audit.cancelAuditExport(taskId: done.taskId),
      );
      expect(cancelledAfterPublish.phase, 'completed');
      expect(cancelledAfterPublish.outputPath, done.outputPath);
      expect(await _exportStep(clock, () => file.readAsBytes()), bytes);
    },
  );

  testWidgets(
    'audit list and CSV share inclusive start and exclusive end ranges',
    (tester) async {
      final clock = Stopwatch()..start();
      const keyword = 'frb-audit-range-';
      final names = [
        for (final suffix in ['a', 'b', 'c']) '$keyword$suffix',
      ];
      for (final name in names) {
        await _exportStep(
          clock,
          () => users.createUser(name: name, role: 'viewer'),
        );
      }
      final all = await _exportStep(
        clock,
        () => audit.listAuditLogs(
          query: _query(keyword: keyword, descending: true),
        ),
      );
      expect(all.total, names.length);
      expect(all.items, hasLength(names.length));
      expect(all.items.map((row) => row.target).toSet(), names.toSet());
      final times = all.items.map((row) => row.at).toList()..sort();
      final firstAt = times.first;
      final lastAt = times.last;
      final at = times[1];
      // Boundaries come from persisted public API rows. No clock ordering or
      // distinct-millisecond assumption: tied rows are included/excluded together.
      final ranges = [
        _query(keyword: keyword, descending: true),
        _query(
          keyword: keyword,
          descending: true,
          startAtMs: at,
          endAtMsExclusive: at + 1,
        ),
        _query(
          keyword: keyword,
          descending: true,
          startAtMs: firstAt - 1,
          endAtMsExclusive: firstAt,
        ),
        _query(
          keyword: keyword,
          descending: true,
          startAtMs: lastAt + 1,
          endAtMsExclusive: lastAt + 2,
        ),
        _query(keyword: keyword, descending: true, startAtMs: at),
        _query(keyword: keyword, descending: true, startAtMs: lastAt + 1),
        _query(keyword: keyword, descending: true, endAtMsExclusive: at),
        _query(keyword: keyword, descending: true, endAtMsExclusive: firstAt),
        _query(
          keyword: keyword,
          descending: true,
          endAtMsExclusive: lastAt + 1,
        ),
      ];
      for (final query in ranges) {
        final expectedRows = all.items
            .where(
              (row) =>
                  (query.startAtMs == null || row.at >= query.startAtMs!) &&
                  (query.endAtMsExclusive == null ||
                      row.at < query.endAtMsExclusive!),
            )
            .toList();
        final listed = await _exportStep(
          clock,
          () => audit.listAuditLogs(query: query),
        );
        expect(listed.total, expectedRows.length);
        expect(
          listed.items.map((row) => row.id).toList(),
          expectedRows.map((row) => row.id).toList(),
        );
        audit.resetAuditExportRegistryForTests();
        final started = await _exportStep(
          clock,
          () => audit.startAuditExport(query: query),
        );
        final done = await _exportTerminal(clock, started);
        expect(done.totalRows, expectedRows.length);
        final file = await _exportStep(clock, () => _exportFile(root, done));
        final expected = StringBuffer(
          '\ufeffid,at_utc_ms,actor,action,target,result\r\n',
        );
        for (final row in expectedRows) {
          expect(row.actor, admin);
          expect(row.action, 'user.create');
          expect(row.result, 'ok');
          expected.write(
            '"${row.id}","${row.at}","$admin","user.create",'
            '"${row.target}","ok"\r\n',
          );
        }
        expect(
          await _exportStep(clock, () => file.readAsBytes()),
          utf8.encode(expected.toString()),
        );
      }
      final before = await _exportStep(clock, () => _exportEntries(root));
      for (final query in [
        _query(keyword: keyword, startAtMs: at, endAtMsExclusive: at),
        _query(keyword: keyword, startAtMs: at + 1, endAtMsExclusive: at),
      ]) {
        await _exportStep(
          clock,
          () => _error(
            () => audit.listAuditLogs(query: query),
            'KEEL-VALIDATION',
          ),
        );
        await _exportStep(
          clock,
          () => _error(
            () => audit.startAuditExport(query: query),
            'KEEL-VALIDATION',
          ),
        );
        expect(await _exportStep(clock, () => _exportEntries(root)), before);
      }
    },
  );

  testWidgets(
    'completed audit export saves an exact copy without overwrite or owner transfer',
    (tester) async {
      final clock = Stopwatch()..start();
      final started = await _exportStep(
        clock,
        () => audit.startAuditExport(query: _query(keyword: 'app.start')),
      );
      final done = await _exportTerminal(clock, started);
      expect(done.totalRows, 1);
      final source = await _exportStep(clock, () => _exportFile(root, done));
      final bytes = await _exportStep(clock, () => source.readAsBytes());
      // Create a fresh destination directory only inside the guarded owned root.
      // Call FRB directly: no native save dialog or mocked platform channel.
      final directory = await _exportStep(
        clock,
        () => root.createTemp('frb-audit-copy-'),
      );
      expect(directory.parent.absolute.uri, root.absolute.uri);
      final destination = File('${directory.path}/copy.csv');
      expect(await _exportStep(clock, () => destination.exists()), isFalse);
      final savedPath = await _exportStep(
        clock,
        () => audit.saveAuditExportCopy(
          taskId: done.taskId,
          destination: destination.path,
        ),
      );
      expect(File(savedPath).absolute.uri, destination.absolute.uri);
      expect(
        await _exportStep(
          clock,
          () => FileSystemEntity.type(destination.path, followLinks: false),
        ),
        FileSystemEntityType.file,
      );
      expect(await _exportStep(clock, () => destination.readAsBytes()), bytes);
      await _exportStep(
        clock,
        () => _error(
          () => audit.saveAuditExportCopy(
            taskId: done.taskId,
            destination: destination.path,
          ),
          'KEEL-DUPLICATE',
        ),
      );
      expect(await _exportStep(clock, () => destination.readAsBytes()), bytes);
      try {
        // Use absent destinations so permission/ownership failures cannot be
        // mistaken for the duplicate-path rejection above.
        for (final name in ['frb-viewer', 'frb-other-admin']) {
          await _exportStep(clock, () => users.switchUser(name: name));
          final forbidden = File('${directory.path}/$name.csv');
          await _exportStep(
            clock,
            () => _error(
              () => audit.saveAuditExportCopy(
                taskId: done.taskId,
                destination: forbidden.path,
              ),
              'KEEL-PERMISSION',
            ),
          );
          expect(await _exportStep(clock, () => forbidden.exists()), isFalse);
          expect(
            await _exportStep(clock, () => destination.readAsBytes()),
            bytes,
          );
        }
      } finally {
        await _exportStep(clock, () => users.switchUser(name: admin));
      }
      expect(await _exportStep(clock, () => source.readAsBytes()), bytes);
      expect(
        await _exportStep(
          clock,
          () => directory
              .list(followLinks: false)
              .map((entry) => entry.absolute.uri.toString())
              .toSet(),
        ),
        {destination.absolute.uri.toString()},
      );
      final reread = await _exportStep(
        clock,
        () => audit.auditExportStatus(taskId: done.taskId),
      );
      expect(reread.phase, 'completed');
      expect(reread.outputPath, done.outputPath);
    },
  );

  testWidgets(
    'audit export permission and owner checks survive user switching',
    (tester) async {
      final clock = Stopwatch()..start();
      final before = await _exportStep(clock, () => _exportEntries(root));
      await _exportStep(clock, () => users.switchUser(name: 'frb-viewer'));
      try {
        await _exportStep(
          clock,
          () => _error(
            () => audit.startAuditExport(query: _query()),
            'KEEL-PERMISSION',
          ),
        );
        expect(await _exportStep(clock, () => _exportEntries(root)), before);
      } finally {
        await _exportStep(clock, () => users.switchUser(name: admin));
      }
      final operator = await _exportStep(
        clock,
        () => users.switchUser(name: 'frb-operator'),
      );
      expect(operator.permissions, contains('audit.export'));
      final started = await _exportStep(
        clock,
        () => audit.startAuditExport(
          query: _query(keyword: 'frb-export-owner-no-matches'),
        ),
      );
      late audit.AuditExportStatus done;
      try {
        // Another admin can export their own data but cannot inspect or cancel
        // this task, regardless of whether its worker has already completed.
        for (final name in ['frb-other-admin', 'frb-viewer']) {
          await _exportStep(clock, () => users.switchUser(name: name));
          await _exportStep(
            clock,
            () => _error(
              () => audit.auditExportStatus(taskId: started.taskId),
              'KEEL-PERMISSION',
            ),
          );
          await _exportStep(
            clock,
            () => _error(
              () => audit.cancelAuditExport(taskId: started.taskId),
              'KEEL-PERMISSION',
            ),
          );
        }
      } finally {
        // Drain the original task as its owner before returning to the shared
        // admin fixture, even if an ownership assertion failed.
        try {
          await _exportStep(
            clock,
            () => users.switchUser(name: 'frb-operator'),
          );
          done = await _exportTerminal(clock, started);
        } finally {
          await _exportStep(clock, () => users.switchUser(name: admin));
        }
      }
      expect(done.phase, 'completed');
      expect(done.totalRows, 0);
      final file = await _exportStep(clock, () => _exportFile(root, done));
      expect(
        await _exportStep(clock, () => file.readAsBytes()),
        utf8.encode('\ufeffid,at_utc_ms,actor,action,target,result\r\n'),
      );
    },
  );

  testWidgets(
    'audit export cancellation reaches a stable terminal without a timing race',
    (tester) async {
      final clock = Stopwatch()..start();
      final before = await _exportStep(clock, () => _exportEntries(root));
      final started = await _exportStep(
        clock,
        () => audit.startAuditExport(query: _query(keyword: 'app.start')),
      );
      final requested = await _exportStep(
        clock,
        () => audit.cancelAuditExport(taskId: started.taskId),
      );
      final terminal = await _exportTerminal(clock, requested);
      // A tiny real database can finish before the cancel FFI call. Both
      // outcomes are legal; never force cancellation by sleep or load inflation.
      expect(terminal.phase, isIn(['cancelled', 'completed']));
      expect(terminal.errorCode, isNull);
      final after = await _exportStep(clock, () => _exportEntries(root));
      if (terminal.phase == 'cancelled') {
        expect(terminal.outputPath, isNull);
        expect(after, before); // No published file or leftover temporary file.
      } else {
        final file = await _exportStep(
          clock,
          () => _exportFile(root, terminal),
        );
        expect(terminal.totalRows, 1);
        expect(after.difference(before), {file.absolute.uri.toString()});
        expect(after.containsAll(before), isTrue);
      }
      final repeated = await _exportStep(
        clock,
        () => audit.cancelAuditExport(taskId: started.taskId),
      );
      final reread = await _exportStep(
        clock,
        () => audit.auditExportStatus(taskId: started.taskId),
      );
      for (final status in [repeated, reread]) {
        expect(status.taskId, terminal.taskId);
        expect(status.phase, terminal.phase);
        expect(status.completedRows, terminal.completedRows);
        expect(status.totalRows, terminal.totalRows);
        expect(status.outputPath, terminal.outputPath);
        expect(status.errorCode, terminal.errorCode);
      }
      expect(await _exportStep(clock, () => _exportEntries(root)), after);
    },
  );

  testWidgets(
    'diagnostic preview exports exact snapshot once with owner checks',
    (tester) async {
      final failure = await _error(
        () => settings.saveSettings(
          settings: settings.Settings(
            language: 'invalid',
            theme: null,
            formatLocale: null,
          ),
        ),
        'KEEL-VALIDATION',
      );
      final events = await diagnostics.recentEvents(
        query: diagnostics.DiagnosticEventQuery(
          limit: 200,
          minLevel: 'error',
          correlationId: ' ${failure.correlationId} ',
        ),
      );
      expect(events, hasLength(1));
      expect(events.single.code, failure.code);
      expect(events.single.correlationId, failure.correlationId);
      final runtime = await diagnostics.prepareDiagnosticPack(
        request: diagnostics.DiagnosticPackRequest(categories: ['runtime']),
      );
      expect(runtime.categories, ['runtime']);
      expect(runtime.eventCount, 0);
      expect(runtime.content, isNot(contains(failure.correlationId)));
      final preview = await diagnostics.prepareDiagnosticPack(
        request: diagnostics.DiagnosticPackRequest(
          categories: ['recent_events', 'runtime', 'recent_events'],
        ),
      );
      expect(preview.categories, ['runtime', 'recent_events']);
      expect(preview.eventCount, greaterThan(0));
      expect(preview.content, contains(failure.correlationId));
      await users.switchUser(name: 'frb-other-admin');
      await _error(
        () => diagnostics.exportPreparedDiagnosticPack(
          previewId: preview.previewId,
        ),
        'KEEL-PERMISSION',
      );
      await users.switchUser(name: admin);
      final path = await diagnostics.exportPreparedDiagnosticPack(
        previewId: preview.previewId,
      );
      final file = File(path);
      expect(
        await file.parent.resolveSymbolicLinks(),
        await Directory('${root.path}/diagnostics').resolveSymbolicLinks(),
      );
      expect(await file.readAsBytes(), utf8.encode(preview.content));
      await _error(
        () => diagnostics.exportPreparedDiagnosticPack(
          previewId: preview.previewId,
        ),
        'KEEL-VALIDATION',
      );
      expect(await file.readAsBytes(), utf8.encode(preview.content));
      for (final categories in <List<String>>[
        [],
        ['logs'],
      ]) {
        await _error(
          () => diagnostics.prepareDiagnosticPack(
            request: diagnostics.DiagnosticPackRequest(categories: categories),
          ),
          'KEEL-VALIDATION',
        );
      }
    },
  );

  testWidgets(
    'backup can be registered and cancelled without applying restore',
    (tester) async {
      expect(await backup.pendingRestore(), isNull);
      final created = await backup.createBackup();
      expect(created.name, matches(r'^keel-\d+\.db$'));
      expect(created.sizeBytes, greaterThan(0));
      expect(
        (await backup.listBackups()).map((item) => item.name),
        contains(created.name),
      );
      try {
        await backup.scheduleRestore(name: created.name);
        expect(await backup.pendingRestore(), created.name);
        await users.switchUser(name: 'frb-operator');
        await _error(
          () => backup.scheduleRestore(name: created.name),
          'KEEL-PERMISSION',
        );
        await _error(() => backup.cancelScheduledRestore(), 'KEEL-PERMISSION');
        expect(await backup.pendingRestore(), created.name);
      } finally {
        await users.switchUser(name: admin);
        await backup.cancelScheduledRestore();
      }
      expect(await backup.pendingRestore(), isNull);
      await backup.cancelScheduledRestore();
      expect(await backup.pendingRestore(), isNull);
      expect(app.appStatus().databaseReady, isTrue);
      expect(app.startupRestoreStatus().outcome, 'none');
      final history = await audit.listAuditLogs(
        query: _query(keyword: 'backup'),
      );
      expect(
        history.items.any((item) => item.action == 'backup.create'),
        isTrue,
      );
      expect(
        history.items.any(
          (item) =>
              item.action == 'backup.restore.schedule' && item.result == 'ok',
        ),
        isTrue,
      );
      expect(
        history.items.any(
          (item) =>
              item.action == 'backup.restore.cancel' && item.result == 'ok',
        ),
        isTrue,
      );
    },
  );

  testWidgets('customers round-trip through the real bridge and audit', (
    tester,
  ) async {
    customers.SaveCustomerRequest request({
      String code = 'frb-cust-1',
      String name = 'FRB 客户',
      bool active = true,
    }) => customers.SaveCustomerRequest(
      code: code,
      name: name,
      kind: 'customer',
      phone: '+86 21 5555 0101',
      email: 'frb@acme.example',
      active: active,
      note: '',
    );

    final id = await customers.createCustomer(request: request());
    expect(id, greaterThan(0));
    final page = await customers.listCustomers(
      query: customers.CustomerQuery(
        keyword: 'frb-',
        kind: null,
        active: null,
        sort: const [],
        page: 1,
        pageSize: 50,
      ),
    );
    expect(page.total, 1);
    // 编号在 Rust 侧统一大写。
    expect(page.items.single.code, 'FRB-CUST-1');
    expect(page.items.single.email, 'frb@acme.example');

    await customers.updateCustomer(
      id: id,
      request: request(name: 'FRB 客户（停用）', active: false),
    );
    final updated = await customers.listCustomers(
      query: customers.CustomerQuery(
        keyword: 'frb-cust-1',
        kind: null,
        active: false,
        sort: const [],
        page: 1,
        pageSize: 50,
      ),
    );
    expect(updated.items.single.active, isFalse);
    expect(updated.items.single.name, 'FRB 客户（停用）');

    // 唯一编号与权限都在 Rust 边界拒绝。
    await _error(
      () => customers.createCustomer(
        request: request(code: 'frb-cust-1', name: '撞号'),
      ),
      'KEEL-DUPLICATE',
    );
    await users.switchUser(name: 'frb-viewer');
    await _error(
      () => customers.createCustomer(
        request: request(code: 'frb-cust-2', name: '只读'),
      ),
      'KEEL-PERMISSION',
    );
    // 读取不分角色。
    final visible = await customers.listCustomers(
      query: customers.CustomerQuery(
        keyword: 'frb-',
        kind: null,
        active: null,
        sort: const [],
        page: 1,
        pageSize: 50,
      ),
    );
    expect(visible.total, 1);

    await users.switchUser(name: admin);
    // 批量启停与删除走同一事务语义；删除后列表为空。
    expect(
      await customers.setCustomersActive(
        ids: Int64List.fromList([id]),
        active: true,
      ),
      1,
    );
    expect(await customers.deleteCustomers(ids: Int64List.fromList([id])), 1);
    final empty = await customers.listCustomers(
      query: customers.CustomerQuery(
        keyword: 'frb-',
        kind: null,
        active: null,
        sort: const [],
        page: 1,
        pageSize: 50,
      ),
    );
    expect(empty.total, 0);
    final history = await audit.listAuditLogs(
      query: _query(keyword: 'customer.', descending: true),
    );
    final actions = history.items.map((item) => item.action).toSet();
    expect(
      actions,
      containsAll(<String>[
        'customer.create',
        'customer.update',
        'customer.activate',
        'customer.delete',
      ]),
    );
    expect(
      history.items.any(
        (item) => item.action == 'customer.update' && item.result == 'ok',
      ),
      isTrue,
    );
  });
}
