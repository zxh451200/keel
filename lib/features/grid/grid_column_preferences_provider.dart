import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/src/rust/api/grid_preferences.dart'
    as rust_grid_preferences;

import 'grid_column_layout.dart';

/// Stable identity for a user-owned layout. It deliberately contains no
/// generated API type, so it can be used before the FRB bridge is available.
class GridLayoutScope {
  const GridLayoutScope({required this.userId, required this.listId})
    : assert(userId != '', 'userId must not be empty'),
      assert(listId != '', 'listId must not be empty');

  final String userId;
  final String listId;

  @override
  bool operator ==(Object other) =>
      other is GridLayoutScope &&
      other.userId == userId &&
      other.listId == listId;

  @override
  int get hashCode => Object.hash(userId, listId);
}

/// Persistence boundary for user-owned layouts.
///
/// Implementations must scope both operations by [userId] and [listId]. The
/// production adapter can translate this contract to Rust without exposing
/// generated bindings to widgets or the layout model.
abstract interface class GridColumnLayoutStore {
  Future<GridColumnLayout?> load(GridLayoutScope scope);
  Future<void> save(GridLayoutScope scope, GridColumnLayout layout);
}

/// Production adapter for the Rust-owned, user-scoped CAS store.
///
/// The Rust boundary derives the authoritative numeric owner ID from the
/// current identity. The Flutter scope remains name-based because it is only
/// a provider key; it is never sent as an authority token.
class RustGridColumnLayoutStore implements GridColumnLayoutStore {
  final Map<GridLayoutScope, _GridRevision> _revisions = {};

  @override
  Future<GridColumnLayout?> load(GridLayoutScope scope) async {
    _validateScope(scope);
    final response = await loadGridPreferencesFromRust(scope.listId);
    _revisions[scope] = _GridRevision(
      ownerId: response.ownerId,
      session: response.session,
      revision: response.revision,
    );
    return GridColumnLayout.fromRustColumns(
      scope.listId,
      response.columns.map(
        (column) => <String, Object?>{
          'id': column.id,
          'width': column.width,
          'visible': column.visible,
          'frozen': column.frozen,
        },
      ),
    );
  }

  @override
  Future<void> save(GridLayoutScope scope, GridColumnLayout layout) async {
    _validateScope(scope);
    if (layout.listId != scope.listId) {
      throw ArgumentError('Layout listId does not match scope');
    }
    final revision = _revisions[scope];
    if (revision == null) {
      throw StateError('Grid layout must be loaded before it is saved');
    }
    final response = await saveGridPreferencesToRust(
      rust_grid_preferences.SaveGridPreferences(
        listId: scope.listId,
        expectedOwnerId: revision.ownerId,
        expectedSession: revision.session,
        expectedRevision: revision.revision,
        columns: layout
            .toRustColumns()
            .map(
              (column) => rust_grid_preferences.GridColumnPreference(
                id: column['id']! as String,
                width: column['width']! as int,
                visible: column['visible']! as bool,
                frozen: column['frozen']! as String,
              ),
            )
            .toList(growable: false),
      ),
    );
    _revisions[scope] = _GridRevision(
      ownerId: response.ownerId,
      session: response.session,
      revision: response.revision,
    );
  }
}

class _GridRevision {
  const _GridRevision({
    required this.ownerId,
    required this.session,
    required this.revision,
  });

  final String ownerId;
  final String session;
  final int revision;
}

/// Small offline implementation useful for tests and for UI development.
/// Each key is isolated by both user and list, and values are copied through
/// the wire shape so callers cannot mutate the stored list indirectly.
class InMemoryGridColumnLayoutStore implements GridColumnLayoutStore {
  final Map<GridLayoutScope, List<Map<String, Object?>>> _values = {};

  @override
  Future<GridColumnLayout?> load(GridLayoutScope scope) async {
    _validateScope(scope);
    final value = _values[scope];
    if (value == null) return null;
    return GridColumnLayout.fromRustColumns(scope.listId, value);
  }

  @override
  Future<void> save(GridLayoutScope scope, GridColumnLayout layout) async {
    _validateScope(scope);
    if (layout.listId != scope.listId) {
      throw ArgumentError('Layout listId does not match scope');
    }
    _values[scope] = [
      for (final column in layout.toRustColumns())
        Map<String, Object?>.from(column),
    ];
  }
}

void _validateScope(GridLayoutScope scope) {
  if (scope.userId.trim().isEmpty || scope.listId.trim().isEmpty) {
    throw ArgumentError('Grid layout scope must identify a user and list');
  }
}

final gridColumnLayoutStoreProvider = Provider<GridColumnLayoutStore>(
  (_) => RustGridColumnLayoutStore(),
);

/// Reads a user's saved layout, falling back to the registered default.
final gridColumnLayoutProvider =
    FutureProvider.family<GridColumnLayout, GridLayoutScope>((
      ref,
      scope,
    ) async {
      final stored = await ref.watch(gridColumnLayoutStoreProvider).load(scope);
      return stored ?? GridColumnLayout.defaults(scope.listId);
    });

/// Reusable settings contract for a settings panel or a future grid adapter.
/// Draft edits stay local until [save] is called; cancellation is represented
/// by simply dropping the returned draft.
class GridColumnSettingsController {
  GridColumnSettingsController(this.initial) : _draft = initial;

  final GridColumnLayout initial;
  GridColumnLayout _draft;

  GridColumnLayout get draft => _draft;

  void update(String id, {int? width, bool? visible, GridFrozen? frozen}) {
    _draft = _draft.update(id, width: width, visible: visible, frozen: frozen);
  }

  void reorder(String id, int target) {
    _draft = _draft.reorder(id, target);
  }

  void reset() {
    _draft = GridColumnLayout.defaults(initial.listId);
  }

  Future<void> save(GridColumnLayoutStore store, GridLayoutScope scope) {
    _validateScope(scope);
    if (_draft.listId != scope.listId) {
      throw ArgumentError('Layout listId does not match scope');
    }
    return store.save(scope, _draft);
  }
}
