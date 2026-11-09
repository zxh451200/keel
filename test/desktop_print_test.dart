import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/api/desktop_print.dart';
import 'package:keel/src/rust/api/error.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('keel/desktop_files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Object? response;

  setUp(() {
    calls = [];
    response = 'printed';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final sanitized = isA<ApiError>()
      .having((e) => e.code, 'code', 'KEEL-PRINT')
      .having((e) => e.message, 'message', '')
      .having((e) => e.correlationId, 'correlationId', '');

  test(
    'preserves full Unicode report and decodes native terminal results',
    () async {
      const content = '审计\t完整\r\nمرحبا\n😀';
      expect(
        await printReport(title: '报告', content: content),
        DesktopPrintResult.printed,
      );
      expect(calls.single.method, 'printReport');
      expect(calls.single.arguments, {'title': '报告', 'content': content});
      response = 'cancelled';
      expect(
        await printReport(title: '报告', content: content),
        DesktopPrintResult.cancelled,
      );
    },
  );

  test(
    'rejects null, unknown and incorrectly typed native responses',
    () async {
      for (final invalid in [null, 'success', 1, true, <String, String>{}]) {
        response = invalid;
        await expectLater(
          printReport(title: 'Report', content: 'text'),
          throwsA(sanitized),
        );
      }
    },
  );

  test('sanitizes platform errors and missing implementations', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'private', message: '/secret/printer');
    });
    await expectLater(
      printReport(title: 'Report', content: 'text'),
      throwsA(sanitized),
    );
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      printReport(title: 'Report', content: 'text'),
      throwsA(sanitized),
    );
  });

  test(
    'limits UTF-8 bytes rather than code units without truncating',
    () async {
      final boundary = List.filled(desktopPrintMaxBytes ~/ 2, 'é').join();
      expect(
        await printReport(title: 'Report', content: boundary),
        DesktopPrintResult.printed,
      );
      await expectLater(
        printReport(title: 'Report', content: '$boundaryé'),
        throwsA(sanitized),
      );
      expect(calls, hasLength(1));
    },
  );

  test(
    'counts CRLF, CR, LF, blank and trailing lines before native calls',
    () async {
      for (final newline in ['\r\n', '\r', '\n']) {
        final boundary = List.filled(200, 'line').join(newline);
        validatePrintReport(title: 'Report', content: boundary);
        await expectLater(
          printReport(title: 'Report', content: '$boundary$newline'),
          throwsA(sanitized),
        );
      }
      expect(calls, isEmpty);
    },
  );

  test('empty text, NUL and oversized titles never reach native', () async {
    for (final invalid in [
      '',
      'secret\u0000hidden',
      List.filled(desktopPrintMaxBytes + 1, 'a').join(),
    ]) {
      await expectLater(
        printReport(title: 'Report', content: invalid),
        throwsA(sanitized),
      );
      await expectLater(
        printReport(title: invalid, content: 'text'),
        throwsA(sanitized),
      );
    }
    expect(calls, isEmpty);
  });

  test(
    'rejects invalid UTF-16 and unsupported controls before native',
    () async {
      for (final invalid in [
        String.fromCharCode(0xd800),
        String.fromCharCode(0xdc00),
        String.fromCharCodes([0xdc00, 0xd800]),
        'before\u0001after',
        'before\u0085after',
        'before\u2028after',
        'before\u2029after',
      ]) {
        await expectLater(
          printReport(title: 'Report', content: invalid),
          throwsA(sanitized),
        );
        await expectLater(
          printReport(title: invalid, content: 'text'),
          throwsA(sanitized),
        );
      }
      await expectLater(
        printReport(title: 'not\na title', content: 'text'),
        throwsA(sanitized),
      );
      expect(calls, isEmpty);
    },
  );
}
