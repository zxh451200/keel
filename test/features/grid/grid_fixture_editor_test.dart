import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keel/features/grid/state/grid_fixture_editor.dart';

GridFixtureRow validRow() => const GridFixtureRow(
  id: 'row-1',
  text: 'fixture',
  quantity: 3,
  date: '2024-02-29',
  kind: 'standard',
);

void main() {
  test('validates the same row boundaries as the fixture service', () {
    expect(validateGridFixtureRow(validRow()), isNull);
    expect(
      validateGridFixtureRow(validRow().copyWith(id: 'bad/id')),
      'invalid-id',
    );
    expect(
      validateGridFixtureRow(validRow().copyWith(text: '')),
      'invalid-text',
    );
    expect(
      validateGridFixtureRow(validRow().copyWith(date: '1900-02-29')),
      'invalid-date',
    );
    expect(
      validateGridFixtureRow(validRow().copyWith(kind: 'other')),
      'invalid-kind',
    );
  });

  test('blocks duplicate saves and resets dirty state after success', () async {
    final gate = Completer<void>();
    var calls = 0;
    final controller = GridFixtureEditorController((row, mode) async {
      calls++;
      expect(mode, GridFixtureSaveMode.update);
      await gate.future;
    }, 'row-1');
    addTearDown(controller.dispose);
    controller.begin(validRow(), GridFixtureSaveMode.update);
    controller.update(validRow().copyWith(text: 'changed'));
    final first = controller.save();
    expect(controller.state.busy, isTrue);
    expect(await controller.save(), isFalse);
    expect(calls, 1);
    gate.complete();
    expect(await first, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.state.dirty, isFalse);
    expect(controller.state.error, isNull);
  });

  test('keeps edited values and exposes a safe error after failure', () async {
    final error = StateError('storage failure');
    final controller = GridFixtureEditorController(
      (_, _) async => throw error,
      'row-1',
    );
    addTearDown(controller.dispose);
    controller.begin(validRow(), GridFixtureSaveMode.create);
    controller.update(validRow().copyWith(quantity: 8));
    expect(await controller.save(), isFalse);
    expect(controller.state.row.quantity, 8);
    expect(controller.state.dirty, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.state.error, same(error));
  });
}
