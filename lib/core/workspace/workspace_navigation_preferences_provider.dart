import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/settings_provider.dart';

/// Only page kinds are persisted, never tab instances or page contents.
class WorkspaceNavigationPreferences {
  WorkspaceNavigationPreferences({
    Iterable<String> recentKinds = const [],
    Iterable<String> favoriteKinds = const [],
    this.navCollapsed = false,
  }) : recentKinds = List.unmodifiable(recentKinds.toSet().take(10)),
       favoriteKinds = List.unmodifiable(favoriteKinds.toSet().take(50));

  final List<String> recentKinds;
  final List<String> favoriteKinds;
  final bool navCollapsed;

  WorkspaceNavigationPreferences copyWith({
    Iterable<String>? recentKinds,
    Iterable<String>? favoriteKinds,
    bool? navCollapsed,
  }) => WorkspaceNavigationPreferences(
    recentKinds: recentKinds ?? this.recentKinds,
    favoriteKinds: favoriteKinds ?? this.favoriteKinds,
    navCollapsed: navCollapsed ?? this.navCollapsed,
  );
}

final initialWorkspaceNavigationPreferencesProvider =
    Provider<WorkspaceNavigationPreferences>(
      (ref) => WorkspaceNavigationPreferences(),
    );

final workspaceNavigationSinkProvider =
    Provider<Future<void> Function(WorkspaceNavigationPreferences)>(
      (ref) => (_) async {},
    );

final workspaceNavigationLoadErrorProvider = Provider<Object?>((ref) => null);
final workspaceNavigationWritableProvider = Provider<bool>((ref) => true);

class WorkspaceNavigationPreferencesNotifier
    extends Notifier<WorkspaceNavigationPreferences> {
  @override
  WorkspaceNavigationPreferences build() =>
      ref.watch(initialWorkspaceNavigationPreferencesProvider);

  void _update(WorkspaceNavigationPreferences next) {
    if (ref.read(preferencesImportGateProvider).blocksWrites) return;
    state = next;
    unawaited(ref.read(workspaceNavigationSaveProvider.notifier).saveLatest());
  }

  void recordVisit(String kind) {
    if (state.recentKinds.isNotEmpty && state.recentKinds.first == kind) return;
    _update(
      state.copyWith(
        recentKinds: [kind, ...state.recentKinds.where((item) => item != kind)],
      ),
    );
  }

  /// Returns false when adding another favorite would exceed the limit.
  bool toggleFavorite(String kind) {
    if (ref.read(preferencesImportGateProvider).blocksWrites) return false;
    final favorites = state.favoriteKinds;
    if (favorites.contains(kind)) {
      _update(
        state.copyWith(favoriteKinds: favorites.where((item) => item != kind)),
      );
    } else {
      if (favorites.length >= 50) return false;
      _update(state.copyWith(favoriteKinds: [...favorites, kind]));
    }
    return true;
  }

  void setNavCollapsed(bool value) {
    if (state.navCollapsed == value) return;
    _update(state.copyWith(navCollapsed: value));
  }

  void applyImported(WorkspaceNavigationPreferences preferences) {
    state = preferences;
  }
}

final workspaceNavigationPreferencesProvider =
    NotifierProvider<
      WorkspaceNavigationPreferencesNotifier,
      WorkspaceNavigationPreferences
    >(WorkspaceNavigationPreferencesNotifier.new);

class WorkspaceNavigationSaveState {
  const WorkspaceNavigationSaveState({this.saving = false, this.error});

  final bool saving;
  final Object? error;
}

class WorkspaceNavigationSaveNotifier
    extends Notifier<WorkspaceNavigationSaveState> {
  Future<void> _tail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  @override
  WorkspaceNavigationSaveState build() {
    ref.onDispose(() => _disposed = true);
    return WorkspaceNavigationSaveState(
      error: ref.read(workspaceNavigationLoadErrorProvider),
    );
  }

  bool get _writable =>
      ref.read(settingsWritableProvider) &&
      ref.read(workspaceNavigationWritableProvider) &&
      ref.read(workspaceNavigationLoadErrorProvider) == null;

  Future<void> saveLatest() {
    if (_disposed ||
        !_writable ||
        ref.read(preferencesImportGateProvider).blocksWrites) {
      return Future<void>.value();
    }
    final revision = ++_revision;
    final snapshot = ref.read(workspaceNavigationPreferencesProvider);
    final save = ref.read(workspaceNavigationSinkProvider);
    _tail = _tail.then((_) async {
      // Recheck protection when the queued write actually starts.
      if (_disposed) return;
      Object? error;
      if (_writable) {
        try {
          await save(snapshot);
        } catch (failure) {
          error = failure;
        }
      } else {
        error = ref.read(workspaceNavigationLoadErrorProvider);
      }
      if (!_disposed && revision == _revision) {
        state = WorkspaceNavigationSaveState(error: error);
      }
    });
    state = const WorkspaceNavigationSaveState(saving: true);
    return _tail;
  }

  Future<void> retry() {
    if (_disposed) return Future<void>.value();
    return state.saving ? _tail : saveLatest();
  }

  Future<void> drain() => _tail;

  void acceptImported() => state = const WorkspaceNavigationSaveState();
}

final workspaceNavigationSaveProvider =
    NotifierProvider<
      WorkspaceNavigationSaveNotifier,
      WorkspaceNavigationSaveState
    >(WorkspaceNavigationSaveNotifier.new);
