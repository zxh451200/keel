// Real FRB + SQLite, in its own process/owned root via integration-check.ps1.
// Pending normal FRB generation; the imports below are the hand-written FRB
// API contract and must resolve after codegen. Never replace missing generated
// APIs with mocks or hand-written generated files.
// In particular, rust/src/api/audit.rs::list_audit_exports returns
// Vec<AuditExportStatus> (Dart List<AuditExportStatus>), not a paginated wrapper;
// lib/api/bridge.dart already calls the pending generated listAuditExports().
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keel/src/rust/api/app.dart' as app;
import 'package:keel/src/rust/api/audit.dart' as audit;
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

// A monotonic deadline includes every FFI call and every short polling yield.
Future<T> _step<T>(Stopwatch clock, Future<T> Function() operation) {
  final remaining = const Duration(seconds: 45) - clock.elapsed;
  if (remaining <= Duration.zero) {
    throw TestFailure('Real FRB operation exceeded the test deadline.');
  }
  return operation().timeout(remaining);
}

audit.AuditQuery _query() => audit.AuditQuery(
  keyword: 'app.start',
  startAtMs: null,
  endAtMsExclusive: null,
  sort: [audit.AuditSort(field: 'at', descending: false)],
  page: 1,
  pageSize: 200,
);

Future<audit.AuditExportStatus> _complete(Stopwatch clock) async {
  var status = await _step(
    clock,
    () => audit.startAuditExport(query: _query()),
  );
  final id = status.taskId;
  while (status.phase == 'running') {
    expect(status.outputPath, isNull);
    // Yield to the real worker without imposing a fixed polling sleep.
    await _step(clock, () => Future<void>.delayed(Duration.zero));
    status = await _step(clock, () => audit.auditExportStatus(taskId: id));
  }
  expect(status.taskId, id);
  expect(status.phase, 'completed');
  expect(status.errorCode, isNull);
  expect(status.completedRows, status.totalRows);
  expect(status.totalRows, 1);
  expect(status.outputPath, isNotNull);
  return status;
}

void _sameStatus(
  audit.AuditExportStatus actual,
  audit.AuditExportStatus expected,
) {
  expect(actual.taskId, expected.taskId);
  expect(actual.phase, expected.phase);
  expect(actual.completedRows, expected.completedRows);
  expect(actual.totalRows, expected.totalRows);
  expect(actual.outputPath, expected.outputPath);
  expect(actual.errorCode, expected.errorCode);
}

void _expectTaskStatusShape(audit.AuditExportStatus status) {
  expect(status.taskId, isNotEmpty);
  expect(status.phase, isIn(['running', 'completed', 'cancelled', 'failed']));
  expect(status.completedRows, greaterThanOrEqualTo(0));
  expect(status.totalRows, greaterThanOrEqualTo(status.completedRows));
  if (status.phase == 'completed') {
    expect(status.outputPath, isNotNull);
    expect(status.errorCode, isNull);
  } else {
    expect(status.outputPath, isNull);
  }
}

Future<diagnostics.DiagnosticHistoryPage> _history(
  Stopwatch clock,
  String text,
) async {
  final page = await _step(
    clock,
    () => diagnostics.searchDiagnosticHistory(
      query: diagnostics.DiagnosticHistoryQuery(text: text),
    ),
  );
  expect(page.lines.length, lessThanOrEqualTo(200));
  expect(page.scannedFiles, inInclusiveRange(0, 14));
  expect(page.scannedBytes, inInclusiveRange(0, 4 * 1024 * 1024));
  expect(page.skippedLines, greaterThanOrEqualTo(0));
  for (final line in page.lines) {
    expect(line.runes.length, lessThanOrEqualTo(2048));
    expect(line, isNot(matches(RegExp(r'[\x00-\x1f\x7f-\x9f]'))));
  }
  return page;
}

// Only fabricated bytes inside the owned root. Reserved future daily names
// avoid touching the active appender file. No links or host data are injected.
Future<void> _withFiles(
  Directory root,
  Map<String, List<int>> contents,
  Future<void> Function() body,
) async {
  final logs = Directory('${root.path}/logs');
  expect(
    await FileSystemEntity.type(logs.path, followLinks: false),
    FileSystemEntityType.directory,
  );
  expect(
    await logs.resolveSymbolicLinks(),
    '${await root.resolveSymbolicLinks()}${Platform.pathSeparator}logs',
  );
  final created = <File>[];
  try {
    for (final entry in contents.entries) {
      // Fixtures may be in logs or immediately outside it, never elsewhere.
      expect(entry.key, matches(RegExp(r'^(logs/)?[a-zA-Z0-9.\-]+$')));
      final file = File('${root.path}/${entry.key}');
      expect(
        await FileSystemEntity.type(file.path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      created.add(file);
      await file.writeAsBytes(entry.value, flush: true);
    }
    await body();
    for (final file in created) {
      final key = contents.keys.singleWhere(
        (key) => File('${root.path}/$key').uri == file.uri,
      );
      expect(await file.readAsBytes(), contents[key]);
    }
  } finally {
    for (final file in created.reversed) {
      expect(
        await FileSystemEntity.type(file.path, followLinks: false),
        FileSystemEntityType.file,
      );
      await file.delete();
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String admin;

  setUpAll(() async {
    root = await _requireIsolation(); // Must precede RustLib.init.
    await RustLib.init();
    await app.initDatabase();
    expect(app.appStatus().databaseReady, isTrue);
    expect(await File('${root.path}/keel.db').exists(), isTrue);
    admin = (await users.currentUser()).name;
    await users.createUser(name: 'history-other-admin', role: 'admin');
    await users.createUser(name: 'history-operator', role: 'operator');
    await users.createUser(name: 'history-viewer', role: 'viewer');
  });
  setUp(() async => users.switchUser(name: admin));
  tearDown(() async => users.switchUser(name: admin));

  testWidgets('task list shape and ID reselection enforce owner scope', (
    tester,
  ) async {
    final clock = Stopwatch()..start();
    // Only three tasks in this entry: stay below the six-slot global registry.
    expect(await _step(clock, () => audit.listAuditExports()), isEmpty);
    final first = await _complete(clock);
    final second = await _complete(clock);
    for (final status in [first, second]) {
      _expectTaskStatusShape(status);
    }
    final source = File(first.outputPath!);
    expect(
      source.absolute.uri,
      File('${root.path}/exports/audit-${first.taskId}.csv').absolute.uri,
    );
    final bytes = await source.readAsBytes();
    await _step(clock, () => users.switchUser(name: 'history-other-admin'));
    expect(await _step(clock, () => audit.listAuditExports()), isEmpty);
    final other = await _complete(clock);
    try {
      final List<audit.AuditExportStatus> otherList = await _step(
        clock,
        () => audit.listAuditExports(),
      );
      expect(otherList, hasLength(1));
      _expectTaskStatusShape(otherList.single);
      _sameStatus(otherList.single, other);
      for (final own in [first, second]) {
        await _step(
          clock,
          () => _error(
            () => audit.auditExportStatus(taskId: own.taskId),
            'KEEL-PERMISSION',
          ),
        );
      }
      await _step(clock, () => users.switchUser(name: admin));
      final beforeAudit = await _step(
        clock,
        () => audit.listAuditLogs(query: _query()),
      );
      // The public FRB contract has no controllable Instant. This side verifies
      // the observable TTL contract without waiting five minutes: repeated
      // list/status reads do not renew the handles, and terminal handles remain
      // readable while inside the 300-second TTL. Exact boundary behavior is
      // covered by the real Rust registry test, which can use deterministic
      // Instants without changing the production API.
      for (var pass = 0; pass < 2; pass++) {
        final listed = await _step(clock, () => audit.listAuditExports());
        expect(listed.map((item) => item.taskId).toList(), [
          second.taskId,
          first.taskId,
        ]);
        for (final expected in [first, second]) {
          final item = listed.singleWhere(
            (item) => item.taskId == expected.taskId,
          );
          _expectTaskStatusShape(item);
          _sameStatus(item, expected);
          _sameStatus(
            await _step(
              clock,
              () => audit.auditExportStatus(taskId: item.taskId),
            ),
            expected,
          );
        }
      }
      await _step(
        clock,
        () => _error(
          () => audit.auditExportStatus(taskId: other.taskId),
          'KEEL-PERMISSION',
        ),
      );
      await _step(
        clock,
        () => _error(
          () => audit.auditExportStatus(taskId: 'missing-frb-handle'),
          'KEEL-NOT-FOUND',
        ),
      );
      final afterAudit = await _step(
        clock,
        () => audit.listAuditLogs(query: _query()),
      );
      expect(afterAudit.total, beforeAudit.total);
      expect(await source.readAsBytes(), bytes);
      await _step(clock, () => users.switchUser(name: 'history-viewer'));
      await _step(
        clock,
        () => _error(() => audit.listAuditExports(), 'KEEL-PERMISSION'),
      );
      await _step(
        clock,
        () => _error(
          () => audit.auditExportStatus(taskId: first.taskId),
          'KEEL-PERMISSION',
        ),
      );
    } finally {
      await _step(clock, () => users.switchUser(name: admin));
    }
    _sameStatus(
      await _step(clock, () => audit.auditExportStatus(taskId: first.taskId)),
      first,
    );
  });

  testWidgets(
    'history validates Unicode bounds and checks viewer permission first',
    (tester) async {
      final clock = Stopwatch()..start();
      for (final text in ['', List.filled(128, '😀').join()]) {
        await _history(
          clock,
          text,
        ); // 128 scalars, 256 UTF-16 code units is valid.
      }
      final invalid = [
        List.filled(129, '😀').join(),
        'query\u0000tail',
        'query\ntail',
        'query\ttail',
        'query\u007ftail',
        'query\u0085tail',
      ];
      for (final text in invalid) {
        await _step(
          clock,
          () => _error(
            () => diagnostics.searchDiagnosticHistory(
              query: diagnostics.DiagnosticHistoryQuery(text: text),
            ),
            'KEEL-VALIDATION',
          ),
        );
      }
      await _step(clock, () => users.switchUser(name: 'history-viewer'));
      for (final text in ['', invalid.first]) {
        await _step(
          clock,
          () => _error(
            () => diagnostics.searchDiagnosticHistory(
              query: diagnostics.DiagnosticHistoryQuery(text: text),
            ),
            'KEEL-PERMISSION',
          ),
        );
      }
      await _step(clock, () => users.switchUser(name: 'history-operator'));
      await _history(clock, 'operator-no-such-line');
    },
  );

  testWidgets(
    'history reads an actual application error after observable persistence',
    (tester) async {
      final clock = Stopwatch()..start();
      final failure = await _step(
        clock,
        () => _error(
          () => settings.saveSettings(
            settings: settings.Settings(
              language: 'invalid-history-language',
              theme: null,
              formatLocale: null,
            ),
          ),
          'KEEL-VALIDATION',
        ),
      );
      // Poll for the actual ID, not an assumed logger flush interval. Each call
      // and yield shares a deadline; an empty result is never accepted as success.
      diagnostics.DiagnosticHistoryPage page;
      do {
        page = await _history(clock, failure.correlationId);
        if (page.lines.isEmpty) {
          // Let the real logger/worker progress; do not encode a timing guess.
          await _step(clock, () => Future<void>.delayed(Duration.zero));
        }
      } while (page.lines.isEmpty);
      expect(page.scannedFiles, greaterThan(0));
      expect(page.scannedBytes, greaterThan(0));
      expect(
        page.lines.every((line) => line.contains(failure.correlationId)),
        isTrue,
      );
      expect(page.lines.any((line) => line.contains(failure.code)), isTrue);
      expect(page.lines.any((line) => line.contains('ERROR')), isTrue);
      final events = await _step(
        clock,
        () => diagnostics.recentEvents(
          query: diagnostics.DiagnosticEventQuery(
            limit: 200,
            minLevel: 'error',
            correlationId: failure.correlationId,
          ),
        ),
      );
      expect(events.single.correlationId, failure.correlationId);
    },
  );

  testWidgets(
    'history selects app logs and redacts before literal case-sensitive matching',
    (tester) async {
      final clock = Stopwatch()..start();
      const marker = 'FRB-History-%_[.]*';
      // Entirely synthetic values; no customer data, real credentials or host paths.
      const raw = 'INFO $marker password=synthetic-history-value\r\n';
      await _withFiles(
        root,
        {
          'logs/keel.log.9999-12-31': utf8.encode(raw),
          'logs/keel.log.9999-12-30': utf8.encode('INFO $marker older\n'),
          'logs/other.log': utf8.encode('INFO $marker ignored-name\n'),
          'logs/keel.log.9999-02-30': utf8.encode(
            'INFO $marker invalid-date\n',
          ),
          'keel.log.9999-12-31': utf8.encode('INFO $marker outside-logs\n'),
        },
        () async {
          final page = await _history(clock, marker);
          expect(page.lines, [
            'INFO $marker password=***',
            'INFO $marker older',
          ]);
          expect(page.truncated, isFalse);
          expect(page.skippedLines, 0);
          expect(
            (await _history(clock, 'synthetic-history-value')).lines,
            isEmpty,
          );
          expect((await _history(clock, '$marker password=***')).lines, [
            'INFO $marker password=***',
          ]);
          expect((await _history(clock, marker.toLowerCase())).lines, isEmpty);
        },
      );
    },
  );

  testWidgets(
    'history skips whole invalid lines and clips output by Unicode scalar',
    (tester) async {
      final clock = Stopwatch()..start();
      final exactInput = 'B${List.filled(8190, 'x').join()}\n'; // 8192 bytes
      final longInput = 'C${List.filled(8191, 'x').join()}\n'; // 8193 bytes
      final exactOutput = List.filled(2048, '中').join();
      final clippedOutput = '${List.filled(2049, '中').join()}FRB-suffix';
      final bytes = <int>[
        ...utf8.encode('$exactInput$longInput$exactOutput\n$clippedOutput\n'),
        ...utf8.encode('invalid-utf8-'),
        0xff,
        10,
        ...utf8.encode('partial-FRB-tail'),
      ];
      await _withFiles(root, {'logs/keel.log.9999-12-31': bytes}, () async {
        final page = await _history(clock, '');
        expect(page.truncated, isTrue);
        expect(page.skippedLines, greaterThanOrEqualTo(3));
        expect(page.lines, contains(exactInput.substring(0, 2048)));
        expect(page.lines, contains(exactOutput));
        expect(page.lines.any((line) => line.startsWith('C')), isFalse);
        expect(
          page.lines.any((line) => line.contains('invalid-utf8-')),
          isFalse,
        );
        expect(
          page.lines.any((line) => line.contains('partial-FRB-tail')),
          isFalse,
        );
        // Match happens on the full safe line BEFORE its visible 2048-scalar cap.
        final suffix = await _history(clock, 'FRB-suffix');
        expect(suffix.lines, [exactOutput]);
        expect(suffix.truncated, isTrue);
      });
    },
  );

  testWidgets('history exposes result, file and byte budget truncation', (
    tester,
  ) async {
    final clock = Stopwatch()..start();
    for (final count in [200, 201]) {
      await _withFiles(
        root,
        {
          'logs/keel.log.9999-12-31': utf8.encode(
            List.generate(count, (i) => 'INFO FRB-budget-$i\n').join(),
          ),
        },
        () async {
          final page = await _history(clock, 'FRB-budget-');
          expect(page.lines, List.generate(200, (i) => 'INFO FRB-budget-$i'));
          expect(page.truncated, count > 200);
          expect(page.skippedLines, 0);
        },
      );
    }
    await _withFiles(
      root,
      {
        for (var day = 1; day <= 15; day++)
          'logs/keel.log.9999-11-${day.toString().padLeft(2, '0')}': utf8
              .encode('INFO FRB-file-budget-$day\n'),
      },
      () async {
        final page = await _history(clock, 'FRB-file-budget-');
        expect(page.scannedFiles, 14);
        expect(page.lines, [
          for (var day = 15; day >= 2; day--) 'INFO FRB-file-budget-$day',
        ]);
        expect(page.truncated, isTrue);
      },
    );
    // Newest file consumes all 4MiB with complete valid lines and no matches;
    // the extra byte forces truncation, independently of the active app log.
    final block = '${List.filled(8191, 'a').join()}\n';
    final bytes = utf8.encode('${List.filled(512, block).join()}x');
    await _withFiles(root, {'logs/keel.log.9999-12-31': bytes}, () async {
      final page = await _history(clock, 'FRB-absent-budget-marker');
      expect(page.lines, isEmpty);
      expect(page.scannedFiles, 1);
      expect(page.scannedBytes, 4 * 1024 * 1024);
      expect(page.truncated, isTrue);
      expect(page.skippedLines, 0);
    });
  });
}
