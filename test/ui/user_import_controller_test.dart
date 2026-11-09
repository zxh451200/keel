import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keel/features/users/state/user_import_controller.dart';

void main() {
  const row = '{"name":"中文","role":"viewer"}';
  test('cancel ack does not replace successful transaction result', () async {
    final result = Completer<int>();
    var runs = 0, cancels = 0;
    final c = UserImportController(
      allowed: () => true,
      prepare: () async => 'ticket',
      run: (id, bytes) {
        expect(id, 'ticket');
        runs++;
        return result.future;
      },
      cancel: (id) async {
        expect(id, 'ticket');
        cancels++;
      },
    );
    addTearDown(c.dispose);
    expect(c.previewText(row), isTrue);
    final pending = c.confirm();
    await Future<void>.value();
    expect(await c.confirm(), isNull);
    await c.requestCancel();
    expect(c.canClose, isFalse);
    result.complete(1);
    expect(await pending, 1);
    expect([runs, cancels], [1, 1]);
    expect(c.canClose, isTrue);
  });
  test('pending cancel protects close after run completes', () async {
    final result = Completer<int>();
    final cancelled = Completer<void>();
    final c = UserImportController(
      allowed: () => true,
      prepare: () async => 'ticket',
      run: (_, _) => result.future,
      cancel: (_) => cancelled.future,
    );
    addTearDown(c.dispose);
    c.previewText(row);
    final pending = c.confirm();
    await Future<void>.value();
    final cancel = c.requestCancel();
    result.complete(1);
    await Future<void>.value();
    expect(c.canClose, isFalse);
    cancelled.complete();
    await cancel;
    expect(await pending, 1);
    expect(c.canClose, isTrue);
  });
  test(
    'identity transition during preparation never dispatches data',
    () async {
      final ticket = Completer<String>();
      var runs = 0, cancels = 0;
      final c = UserImportController(
        allowed: () => true,
        prepare: () => ticket.future,
        run: (_, _) async {
          runs++;
          return 1;
        },
        cancel: (_) async {
          cancels++;
        },
      );
      addTearDown(c.dispose);
      c.previewText(row);
      final pending = c.confirm();
      c.invalidate();
      ticket.complete('ticket');
      expect(await pending, isNull);
      expect([runs, cancels], [0, 1]);
      expect(c.previewText(row), isFalse);
    },
  );
  testWidgets(
    'progress is single flight and late samples cannot settle a run',
    (tester) async {
      final result = Completer<int>();
      final sample = Completer<ImportProgress?>();
      var polls = 0;
      final c = UserImportController(
        allowed: () => true,
        prepare: () async => 'ticket',
        run: (_, _) => result.future,
        cancel: (_) async {},
        readProgress: (_) {
          polls++;
          return sample.future;
        },
      );
      addTearDown(c.dispose);
      c.previewText(row);
      final pending = c.confirm();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 2));
      expect(polls, 1);
      result.complete(1);
      await tester.pump();
      expect(c.canClose, isFalse);
      sample.complete((processed: 1, total: 1));
      await tester.pump();
      expect(await pending, 1);
      expect(c.progress, isNull);
      expect(c.canClose, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(polls, 1);
    },
  );
  testWidgets('progress errors retry observation without restarting import', (
    tester,
  ) async {
    final result = Completer<int>();
    var polls = 0, runs = 0;
    final c = UserImportController(
      allowed: () => true,
      prepare: () async => 'ticket',
      run: (_, _) {
        runs++;
        return result.future;
      },
      cancel: (_) async {},
      readProgress: (_) async {
        polls++;
        if (polls == 1) throw StateError('transport');
        return (processed: 1, total: 1);
      },
    );
    addTearDown(c.dispose);
    c.previewText(row);
    final pending = c.confirm();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.error, isNull);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.progress, (processed: 1, total: 1));
    expect(c.canClose, isFalse);
    expect(runs, 1);
    result.completeError(StateError('rollback'));
    await tester.pump();
    expect(await pending, isNull);
    expect(c.error, UserImportError.failed);
    expect(c.progress, isNull);
  });
  test('bounds reject input and failure consumes the preview', () async {
    final c = UserImportController(
      allowed: () => true,
      prepare: () async => 'ticket',
      run: (_, _) async => throw StateError('private'),
      cancel: (_) async {},
    );
    addTearDown(c.dispose);
    expect(c.previewText(List.filled(1048577, 'a').join()), isFalse);
    expect(c.previewText(List.filled(1001, row).join('\n')), isFalse);
    expect(c.previewText('$row\n\n'), isFalse);
    expect(c.previewText('{"name":"a","role":"admin"}'), isFalse);
    expect(c.previewText('$row\r\n'), isTrue);
    expect(await c.confirm(), isNull);
    expect(c.error, UserImportError.failed);
    expect(c.preview, isNull);
    expect(await c.confirm(), isNull);
  });
}
