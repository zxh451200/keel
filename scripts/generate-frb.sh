#!/usr/bin/env bash
# Run real generators on Linux; never synthesize binding files.
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$project_root"

for tool in flutter dart rustc cargo flutter_rust_bridge_codegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$tool" >&2
    exit 1
  fi
done

if command -v sha256sum >/dev/null 2>&1; then
  sha256_files() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_files() { shasum -a 256 "$@"; }
else
  printf "Missing SHA-256 tool: sha256sum or shasum\n" >&2
  exit 1
fi

frb_version="$(flutter_rust_bridge_codegen --version)"
if [[ ! "$frb_version" =~ (^|[[:space:]])2\.13\.0($|[[:space:]]) ]]; then
  printf 'FRB codegen 2.13.0 is required.\n' >&2
  exit 1
fi
flutter_version="$(flutter --version)"
if [[ ! "$flutter_version" =~ ^Flutter[[:space:]]3\.47\.8[[:space:]] ]]; then
  printf 'Flutter 3.47.8 is required by the project CI baseline.\n' >&2
  exit 1
fi

lock_before="$(sha256_files pubspec.lock rust/Cargo.lock)"
export PUB_HOSTED_URL=https://pub.dev
flutter pub get --enforce-lockfile
cargo fetch --manifest-path rust/Cargo.toml --locked
flutter gen-l10n
flutter_rust_bridge_codegen generate

lock_after="$(sha256_files pubspec.lock rust/Cargo.lock)"
if [[ "$lock_before" != "$lock_after" ]]; then
  printf 'Lock files changed; inspect changes before proceeding.\n' >&2
  exit 1
fi
printf 'Generators completed. Review outputs and run compiler/test gates.\n'
