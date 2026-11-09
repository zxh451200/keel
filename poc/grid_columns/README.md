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

No Flutter/Dart SDK is available on the editing host. Resolution, formatting,
analysis and tests have not run. Root Python source checks do not validate this
package. These tests cover adaptation, not rendering, editing, clipboard behavior,
memory use or platform acceptance.
