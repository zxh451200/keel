import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:keel/features/users/state/user_draft.dart'
    show normalizeUserName;

enum UserImportError { validation, failed, cancelFailed, cancelled }

typedef ImportProgress = ({int processed, int total});

class UserImportController extends ChangeNotifier {
  UserImportController({
    required this.allowed,
    required this.prepare,
    required this.run,
    required this.cancel,
    this.isCancellation,
    this.readProgress,
  });
  final bool Function() allowed;
  final Future<String> Function() prepare;
  final Future<int> Function(String, Uint8List) run;
  final Future<void> Function(String) cancel;
  final bool Function(Object)? isCancellation;
  final Future<ImportProgress?> Function(String)? readProgress;
  Timer? _pollTimer;
  Future<void>? _polling;
  bool _observing = false;
  ImportProgress? _progress;
  ImportProgress? get progress => _progress;
  String? _preview, _ticket;
  bool _working = false, _cancelRequested = false;
  bool _stale = false, _disposed = false;
  Future<void>? _cancellation;
  UserImportError? _error;
  String? get preview => _preview;
  UserImportError? get error => _error;
  bool get busy => _working;
  bool get canClose => !busy;
  bool get stale => _stale;
  bool get cancelRequested => _cancelRequested;
  bool get _live => !_disposed && !_stale && allowed();
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _scheduleProgress(String ticket) {
    if (!_observing || !_live || readProgress == null) return;
    _pollTimer = Timer(const Duration(milliseconds: 500), () {
      _polling = _readProgress(ticket);
    });
  }

  Future<void> _readProgress(String ticket) async {
    try {
      final value = await readProgress!(ticket);
      if (_observing &&
          _live &&
          _ticket == ticket &&
          value != null &&
          value.total > 0 &&
          value.total <= 1000 &&
          value.processed >= 0 &&
          value.processed <= value.total) {
        _progress = value;
        _emit();
      }
    } catch (_) {
      // Observation failure cannot settle or restart the transaction.
    } finally {
      _scheduleProgress(ticket);
    }
  }

  void changed() {
    if (!_live || busy) return;
    _preview = null;
    _progress = null;
    _error = null;
    _emit();
  }

  bool previewText(String text) {
    if (!_live || busy) return false;
    changed();
    try {
      if (text.isEmpty ||
          text.length > 1048576 ||
          utf8.encode(text).length > 1048576) {
        throw const FormatException();
      }
      final lines = text.split('\n');
      if (lines.last.isEmpty) lines.removeLast();
      if (lines.isEmpty || lines.length > 1000) throw const FormatException();
      final names = <String>{};
      for (var line in lines) {
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        if (utf8.encode(line).length > 4096) throw const FormatException();
        final row = jsonDecode(line);
        if (row is! Map ||
            row.length != 2 ||
            row['name'] is! String ||
            !const ['viewer', 'operator'].contains(row['role'])) {
          throw const FormatException();
        }
        final name = normalizeUserName(row['name'] as String);
        if (name.isEmpty ||
            name.runes.length > 32 ||
            name.runes.any((r) => r <= 0x1f || r >= 0x7f && r <= 0x9f) ||
            !names.add(name)) {
          throw const FormatException();
        }
      }
      _preview =
          text; // Rust performs authoritative validation and atomic writes.
    } catch (_) {
      _error = UserImportError.validation;
    }
    _emit();
    return _preview != null;
  }

  Future<void> requestCancel() {
    if (!_working) return Future<void>.value();
    _cancelRequested = true;
    _emit();
    final ticket = _ticket;
    if (ticket == null) return Future<void>.value();
    return _cancellation ??= _sendCancel(ticket);
  }

  Future<void> _sendCancel(String ticket) async {
    try {
      await cancel(ticket);
    } catch (_) {
      if (_live) _error = UserImportError.cancelFailed;
    }
    _emit();
  }

  void invalidate() {
    _stale = true;
    _observing = false;
    _pollTimer?.cancel();
    _progress = null;
    _preview = null;
    unawaited(requestCancel());
    _emit();
  }

  Future<int?> confirm() async {
    if (!_live || busy || _preview == null) return null;
    final bytes = Uint8List.fromList(utf8.encode(_preview!));
    _preview = null;
    _working = true;
    _cancelRequested = false;
    _cancellation = null;
    _error = null;
    _progress = null;
    _emit();
    try {
      _ticket = await prepare();
      if (!_live || _cancelRequested) {
        await requestCancel();
        return null;
      }
      _observing = true;
      _scheduleProgress(_ticket!);
      final result = await run(_ticket!, bytes);
      return _live ? result : null;
    } catch (error) {
      if (_live) {
        _error = isCancellation?.call(error) == true
            ? UserImportError.cancelled
            : UserImportError.failed;
      }
      return null;
    } finally {
      _observing = false;
      _pollTimer?.cancel();
      // Retain the guard until every native call for this operation settles.
      await _polling;
      _polling = null;
      // Do not release close protection while a native cancel call is pending.
      await _cancellation;
      _ticket = null;
      _working = false;
      _progress = null;
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    invalidate();
    super.dispose();
  }
}
