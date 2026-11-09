# trina_grid comparison POC

Isolated sibling of `poc/grid_columns`, ported 1:1 to `trina_grid 2.4.0` to run
the same matrix required by `docs/GRID_POC.md` before locking either candidate.
Not part of the application build; the root locks do not cover this package.

The page, fixture contract, column adapter and the original test bodies are the
same as the pluto POC (symbols renamed Pluto → Trina). Differences:

- `test/trina_defect_probes_test.dart` probes the five pluto_grid 8.1.0 defects
  against trina and pins two trina-only behaviors (native column validator,
  silent lazy-fetch errors).
- The pluto defect-5 reproduction runs here without `skip`: trina's
  `TrinaLazyPagination.setPage` guards with `mounted` + a fetch version.
- New trina hazard found by the port: default shortcuts are `SingleActivator`s
  (identity equality only) and `TrinaGridShortcut.handle` runs the first match
  in insertion order, so neither a pluto-style `LogicalKeySet` override nor a
  same-shape key replacement displaces the built-in paste. The page drops the
  built-in paste entries by action type and registers the safe action for the
  control and meta variants; a real-dispatch test pins this.

## Fluent host

`test/fluent_host_test.dart` (added to both POCs) hosts the page in FluentApp
with FluentThemeData, since the production shell is Fluent, not Material.
Seven cases: render/fetch, light and dark theme, real ArrowDown, real Ctrl+C,
real oversized Ctrl+V, key routing after a Fluent ContentDialog, and entering
edit mode on a Fluent page with no Material ancestor. All seven pass here;
the last one fails on pluto_grid 8.1.0 (it throws `No Material widget found`),
which trina 2.4.0 avoids by wrapping the grid in a transparency Material when
the host has none (trina issue #423). Both candidates still require the host to
supply Flutter's `MaterialLocalizations` delegates — FluentApp only contributes
the standalone `material_ui` ones — which the production app already does.

Gate results 2026-11-09: `flutter test` 62 passed / 0 skipped, `flutter analyze`
clean, `dart format` no diffs; lock resolved from pub.dev (91 packages, including
test-only `fluent_ui 4.17.0`).

Supply chain (2026-11-09): official archive SHA-256
`cda88c3ad69748f54cf2bedb7c8e9af4a6a2e128dd994dbfb8e604d92f463a83` matches
pub.dev metadata; package LICENSE is MIT (Copyright (c) [2020] [TrinaGrid]).
Resolution adds 58 packages over the pluto lock (pdf, shadcn_ui and their
transitives); all scanned LICENSE files are MIT / BSD-3-Clause / Apache-2.0.
`pubspec.lock` is pinned to https://pub.dev (the local `flutter` wrapper script
forces a Tsinghua mirror; run the SDK tools directly with
`PUB_HOSTED_URL=https://pub.dev`).

Run from this package directory:

```bash
flutter pub get
flutter gen-l10n
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Real OS-level key focus and window behavior, process memory, DPI/screen readers
and the Windows/Linux platform matrix remain NOT RUN; the Fluent host suite
above is widget-level only.