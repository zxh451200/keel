import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:keel/src/rust/api/error.dart';

enum DesktopPrintResult { printed, cancelled }

const desktopPrintMaxBytes = 1024 * 1024;
const desktopPrintMaxLines = 200;
const _channel = MethodChannel('keel/desktop_files');

ApiError _printError() =>
    ApiError(code: 'KEEL-PRINT', message: '', correlationId: '');

/// Validate the exact complete preview, including its title and blank lines.
/// CRLF counts once, lone CR/LF once each; a trailing newline adds a line.
void validatePrintReport({required String title, required String content}) {
  bool valid(String text, {required bool body}) {
    if (text.isEmpty || text.length > desktopPrintMaxBytes) return false;
    final units = text.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          return false;
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
      final allowedBreak = body && (unit == 9 || unit == 10 || unit == 13);
      if ((unit < 32 && !allowedBreak) ||
          (unit >= 0x7f && unit <= 0x9f) ||
          unit == 0x2028 ||
          unit == 0x2029) {
        return false;
      }
    }
    return utf8.encode(text).length <= desktopPrintMaxBytes;
  }

  if (!valid(title, body: false) ||
      !valid(content, body: true) ||
      RegExp(r'\r\n|\r|\n').allMatches(content).length + 1 >
          desktopPrintMaxLines) {
    throw _printError();
  }
}

/// A printed result confirms submission only, never physical delivery.
Future<DesktopPrintResult> printReport({
  required String title,
  required String content,
}) async {
  validatePrintReport(title: title, content: content);
  try {
    final result = await _channel.invokeMethod<Object?>('printReport', {
      'title': title,
      'content': content,
    });
    return switch (result) {
      'printed' => DesktopPrintResult.printed,
      'cancelled' => DesktopPrintResult.cancelled,
      _ => throw _printError(),
    };
  } on PlatformException {
    throw _printError();
  } on MissingPluginException {
    throw _printError();
  }
}
