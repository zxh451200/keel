# Column layout adapter POC

This isolated Flutter package evaluates Keel's column layout contract against
PlutoGrid 8.1.0. It is not part of the application build.

`GridColumns` validates complete column sets, widths 80–800, visibility and
start/none/end ordering against the Rust service contract.
`createPlutoColumns` validates every factory result before applying preferences.
Callers must return fresh, unattached columns; passing columns from a live grid
is unsupported. Column types and editing policy remain with the caller.

Persistence, owner/session/revision checks and final validation remain in Rust.
No hand-written FRB interface is included.

Status 2026-11-09: the gates have run on this machine. `flutter analyze` reports
no issues, `dart format` has no diffs, and `flutter test` is 54 passed + 2
justified skips (the pinned lazy-pagination dispose repro and the Fluent-host
Material-ancestor probe below). The package lock resolved from pub.dev (35
packages), including the test-only `fluent_ui 4.17.0` host dependency.

## Fluent host

`test/fluent_host_test.dart` is the same 7-case instrument as the trina POC,
with FluentApp + FluentThemeData as the app root instead of MaterialApp. Six
cases pass here: render/fetch, light and dark theme, real ArrowDown, real
Ctrl+C, real oversized Ctrl+V, and key routing after a Fluent ContentDialog.

The seventh is a pinned probe, skipped with a reason: pluto_grid 8.1.0 throws
`No Material widget found` when a cell editor opens on a Fluent page without a
Material ancestor; trina 2.4.0 passes because it wraps the grid in a
transparency Material on demand. The same run also showed that both candidates
need the host to provide Flutter's `MaterialLocalizations` delegates, since
FluentApp only contributes the standalone `material_ui` delegates.

Run from this package directory with a compatible Flutter SDK:

```bash
flutter pub get
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
```

First resolution must create and retain this package's own `pubspec.lock`.
Root locks and scans do not cover this package. Before candidate acceptance,
review resolved transitive licenses and security reports, verify the pub.dev
archive against tagged source, and run the repository's `docs/GRID_POC.md` matrix.

The upstream [8.1.0 LICENSE](https://raw.githubusercontent.com/bosskmk/pluto_grid/8.1.0/LICENSE)
was read on 2026-11-05: MIT, Copyright (c) [2020] [PlutoGrid].
This source check does not complete the dependency audit.

These tests cover adaptation, rendering, editing and clipboard behavior in
widget tests. They do not cover real OS focus, process memory, DPI/screen
readers or platform acceptance.
