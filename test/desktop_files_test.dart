import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/api/desktop_files.dart';
import 'package:keel/src/rust/api/error.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('keel/desktop_files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<String?> choose() =>
      selectExternalDiagnosticFile('title', 'filter', 'cancel', 'open');

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'diagnostic selection uses its own method and localized labels',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'selectExternalDiagnosticFile');
        expect(call.arguments, {
          'title': 'title',
          'filterLabel': 'filter',
          'cancelLabel': 'cancel',
          'openLabel': 'open',
        });
        return '/tmp/diagnostic.log';
      });
      expect(await choose(), '/tmp/diagnostic.log');
    },
  );

  test('cancel returns null', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await choose(), isNull);
  });

  test('native errors do not expose paths or sensitive details', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'native-error',
        message: '/private/source.log secret',
        details: 'sensitive details',
      );
    });
    await expectLater(
      choose(),
      throwsA(
        isA<ApiError>()
            .having((e) => e.code, 'code', 'KEEL-IO')
            .having((e) => e.message, 'message', '')
            .having((e) => e.correlationId, 'correlationId', ''),
      ),
    );
  });

  test('missing platform implementation returns a stable error', () async {
    await expectLater(
      choose(),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'KEEL-IO')),
    );
  });
}
