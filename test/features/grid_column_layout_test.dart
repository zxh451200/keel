import 'package:flutter_test/flutter_test.dart';
import 'package:keel/features/grid/grid_column_layout.dart';
import 'package:keel/features/grid/grid_column_preferences_provider.dart';

GridColumnPreference column(
  String id, {
  int width = GridColumnLayout.defaultWidth,
  bool visible = true,
  GridFrozen frozen = GridFrozen.none,
}) => GridColumnPreference(
  id: id,
  width: width,
  visible: visible,
  frozen: frozen,
);

void main() {
  test('defaults and Rust wire shape match both supported lists', () {
    expect(GridColumnLayout.defaults('audit_log').columns.first.id, 'at');
    for (final listId in ['audit_log', 'grid_poc_fixture']) {
      final layout = GridColumnLayout.defaults(listId);
      expect(layout.columns, hasLength(5));
      expect(layout.toRustColumns().first, {
        'id': layout.columns.first.id,
        'width': 160,
        'visible': true,
        'frozen': 'none',
      });
    }
  });

  test('updates visibility and width and clears frozen state when hidden', () {
    final layout = GridColumnLayout('grid_poc_fixture', [
      column('id', frozen: GridFrozen.start),
      column('text'),
      column('quantity'),
      column('date'),
      column('kind', frozen: GridFrozen.end),
    ]);
    final updated = layout.update('id', visible: false);
    expect(updated['id'].visible, isFalse);
    expect(updated['id'].frozen, GridFrozen.none);
    expect(updated.update('text', width: 800)['text'].width, 800);
  });

  test('moves only within a frozen group', () {
    final layout = GridColumnLayout('grid_poc_fixture', [
      column('id', frozen: GridFrozen.start),
      column('text', frozen: GridFrozen.start),
      column('quantity'),
      column('date'),
      column('kind', frozen: GridFrozen.end),
    ]);
    expect(layout.move('text', -1).columns.map((c) => c.id), [
      'text',
      'id',
      'quantity',
      'date',
      'kind',
    ]);
    expect(layout.move('quantity', -1), same(layout));
  });

  test('rejects incomplete, hidden-frozen, and invalid group layouts', () {
    final defaults = GridColumnLayout.defaults('grid_poc_fixture').columns;
    expect(
      () => GridColumnLayout('grid_poc_fixture', defaults.sublist(1)),
      throwsFormatException,
    );
    expect(
      () => GridColumnLayout('grid_poc_fixture', [
        column('id', visible: false, frozen: GridFrozen.start),
        ...defaults.sublist(1),
      ]),
      throwsFormatException,
    );
    expect(
      () => GridColumnLayout('grid_poc_fixture', [
        column('id'),
        column('text', frozen: GridFrozen.start),
        ...defaults.sublist(2),
      ]),
      throwsFormatException,
    );
    expect(
      () => GridColumnLayout('grid_poc_fixture', [
        for (final item in defaults) item.copyWith(visible: false),
      ]),
      throwsFormatException,
    );
    expect(
      () => GridColumnLayout('grid_poc_fixture', [
        column('id', visible: false),
        column('text', frozen: GridFrozen.start),
        ...defaults.sublist(2),
      ]),
      throwsFormatException,
    );
    expect(
      () => GridColumnLayout('grid_poc_fixture', [
        column('id', frozen: GridFrozen.start),
        column('text', frozen: GridFrozen.end),
        column('quantity', visible: false),
        ...defaults.sublist(3),
      ]),
      throwsFormatException,
    );
  });

  test('round trips the Rust wire shape without generated bindings', () {
    final layout = GridColumnLayout('grid_poc_fixture', [
      column('id', width: 120, frozen: GridFrozen.start),
      column('text', visible: false),
      column('quantity'),
      column('date'),
      column('kind', frozen: GridFrozen.end),
    ]);
    final restored = GridColumnLayout.fromRustColumns(
      'grid_poc_fixture',
      layout.toRustColumns(),
    );
    expect(restored.columns, orderedEquals(layout.columns));
    expect(
      () => GridColumnPreference.fromJson({'id': 'id'}),
      throwsFormatException,
    );
  });

  test('reorders only inside the same frozen group', () {
    final layout = GridColumnLayout('grid_poc_fixture', [
      column('id', frozen: GridFrozen.start),
      column('text', frozen: GridFrozen.start),
      column('quantity'),
      column('date'),
      column('kind', frozen: GridFrozen.end),
    ]);
    expect(layout.reorder('id', 1).columns.map((c) => c.id), [
      'text',
      'id',
      'quantity',
      'date',
      'kind',
    ]);
    expect(layout.reorder('id', 2), same(layout));
    expect(layout.reorder('id', -1), same(layout));
  });

  test('isolates stored layouts by user and list', () async {
    final store = InMemoryGridColumnLayoutStore();
    const alice = GridLayoutScope(userId: 'alice', listId: 'grid_poc_fixture');
    const bob = GridLayoutScope(userId: 'bob', listId: 'grid_poc_fixture');
    final changed = GridColumnLayout.defaults(alice.listId)
        .update('id', width: 240);
    await store.save(alice, changed);
    expect((await store.load(alice))!['id'].width, 240);
    // bob 从未保存：内存存储按契约返回 null，由上层 provider 回退默认布局。
    expect(await store.load(bob), isNull);
  });

  test('settings controller keeps draft local until save', () async {
    const scope = GridLayoutScope(userId: 'alice', listId: 'grid_poc_fixture');
    final store = InMemoryGridColumnLayoutStore();
    final settings = GridColumnSettingsController(
      GridColumnLayout.defaults(scope.listId),
    );
    settings.update('id', width: 240);
    expect((await store.load(scope)), isNull);
    await settings.save(store, scope);
    expect((await store.load(scope))!['id'].width, 240);
    settings.reset();
    expect(settings.draft['id'].width, GridColumnLayout.defaultWidth);
  });

  test('parses only Rust frozen values', () {
    expect(GridFrozenWire.parse('start'), GridFrozen.start);
    expect(GridFrozenWire.parse('none'), GridFrozen.none);
    expect(GridFrozenWire.parse('end'), GridFrozen.end);
    expect(() => GridFrozenWire.parse('middle'), throwsFormatException);
  });
}
