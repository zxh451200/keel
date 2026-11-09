# Changelog

All notable changes to Keel are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) conventions.

## [Unreleased]

### Added

- `trina_grid 2.4.0` selected as the production data grid after the same-case
  POC comparison; the customer list now uses its row selection, virtual
  scrolling and shortcut handling while editing stays in the existing dialogs.
- Rust edition 2024 migration with a pinned `rustfmt` style edition for
  generated FRB code.
- Automated display-region coverage: system locale follow/explicit override,
  view-menu persistence, and audit timestamp reformatting by region/time zone.
- A desktop integration entry for real-window keyboard selection and a
  five-cycle RSS lifecycle sample.
- Current-page audit row selection, keyboard navigation, formula-safe TSV copy,
  and aligned horizontal scrolling in the Fluent UI.
- Shared Fluent visual tokens, current UI extension guidance, and public API
  migration boundaries.
- RustSec snapshot observations and scan report/lock-file byte verification
  in release evidence; unknown OSV database provenance still blocks release.
- Release candidate workflow for protected `v*` tags.
- Release evidence generation for Windows candidates: SHA-256 manifest,
  SPDX 2.3 file inventory, build metadata, license files, and security reports.
- Backup restore marker and temporary database symlink boundary hardening.

### Verification status

- Windows Release build verification predates this batch. The new desktop
  changes still require Flutter analysis, widget tests, and Windows checks;
  this Linux editing session has no Flutter/Cargo executable in PATH.
- Python script regressions: 42 passed. Synthetic SQLite query benchmarks ran
  at 10k/100k/1m rows in warm and reconnect modes; these are not UI benchmarks.
- The release workflow is source-complete but has not run in this environment.
- Authenticode signing, Defender records, installer packaging, clean-machine
  install/upgrade/uninstall checks, attestation, and official publication remain
  separate release gates.

## [1.0.0] - Unreleased

The initial product baseline is still under development and has not been
released.
- Internal external-diagnostic text screening and immutable redacted snapshots;
  public API and UI integration remain pending.
- Isolated synthetic editing/JSONL import fixture with transactional rollback
  and cooperative cancellation; not connected to the product database or grid.
- Windows/Linux plain-text print adapters and a Dart channel/report builder;
  preview, authorization, busy guards, and UI integration remain pending.
- Current activity details and navigation for the six existing busy categories.
