#!/usr/bin/env python3
"""Read-only source checks using Python 3.8+, without Flutter/Rust SDKs.

This does not parse Dart/Rust or prove compilation, license compliance or safety.
Default mode fails for missing generated imports/localization declarations and
unlocked direct dependencies. It does not prove regenerated files are identical.
--allow-pending-generation reports those as PENDING for offline source editing.
"""

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8-sig")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def check_l10n(errors):
    resources = {}
    for locale in ("en", "zh"):
        try:
            resources[locale] = json.loads(
                read("lib/l10n/app_" + locale + ".arb"),
                object_pairs_hook=unique_object,
            )
            if not isinstance(resources[locale], dict):
                errors.append("l10n resource must be an object: " + locale)
                del resources[locale]
        except (ValueError, OSError) as error:
            errors.append(str(error))
    if len(resources) != 2:
        return
    en, zh = resources["en"], resources["zh"]
    en_keys = {key for key in en if not key.startswith("@")}
    zh_keys = {key for key in zh if not key.startswith("@")}
    for key in sorted(en_keys ^ zh_keys):
        errors.append("l10n key missing in one locale: " + key)
    for key in sorted(en_keys & zh_keys):
        if not isinstance(en[key], str) or not isinstance(zh[key], str):
            errors.append("l10n value must be text: " + key)
            continue
        # Matches ordinary and ICU plural/select argument names; not a full ICU parser.
        names = lambda text: set(re.findall(r"\{(\w+)\s*[,}]", text))
        if names(en[key]) != names(zh[key]):
            errors.append("l10n placeholders differ: " + key)
        for locale, resource in (("en", en), ("zh", zh)):
            # Translation metadata is optional; if present, it must agree.
            if locale != "en" and "@" + key not in resource:
                continue
            metadata = resource.get("@" + key, {})
            if not isinstance(metadata, dict):
                errors.append("l10n metadata must be an object: {}.{}".format(locale, key))
                continue
            placeholders = metadata.get("placeholders", {})
            if not isinstance(placeholders, dict) or any(
                not isinstance(value, dict) for value in placeholders.values()
            ):
                errors.append("l10n placeholders must be objects: {}.{}".format(locale, key))
                continue
            if names(resource[key]) != set(placeholders):
                errors.append("l10n placeholder metadata differs: {}.{}".format(locale, key))
    for path in (ROOT / "lib").rglob("*.dart"):
        if "src/rust" in path.as_posix() or path.name.startswith("app_localizations"):
            continue
        text = path.read_text(encoding="utf-8")
        for key in set(re.findall(r"\bt\.(\w+)", text)):
            if key not in en_keys:
                errors.append("{}: missing l10n key {}".format(
                    path.relative_to(ROOT), key,
                ))


def check_imports(errors, pending):
    seen = set()
    for folder in ("lib", "test", "integration_test"):
        for path in (ROOT / folder).rglob("*.dart"):
            text = path.read_text(encoding="utf-8")
            imports = re.findall(
                r"""(?:import|export)\s+['"]package:keel/([^'"]+)['"]""", text,
            )
            for relative in imports:
                target = ROOT / "lib" / relative
                if target.exists() or relative in seen:
                    continue
                seen.add(relative)
                if relative.startswith("src/rust/") or relative.startswith(
                    "l10n/app_localizations"
                ):
                    pending.append("missing generated file: lib/" + relative)
                else:
                    errors.append("missing local import: lib/" + relative)


def check_generated_l10n(pending):
    """Detect missing generated declarations, not full generator equivalence."""
    template = json.loads(read("lib/l10n/app_en.arb"), object_pairs_hook=unique_object)
    for relative in (
        "lib/l10n/app_localizations.dart",
        "lib/l10n/app_localizations_en.dart",
        "lib/l10n/app_localizations_zh.dart",
    ):
        target = ROOT / relative
        if not target.is_file():
            pending.append("missing generated file: " + relative)
            continue
        text = target.read_text(encoding="utf-8-sig")
        for key in sorted(key for key in template if not key.startswith("@")):
            # Flutter emits String get foo or String foo(...), including ICU.
            if not re.search(r"\bString\s+(?:get\s+)?" + re.escape(key) +
                             r"\s*(?:\(|=>|\{|;)", text):
                pending.append("{}: missing generated l10n declaration {}".format(
                    relative, key,
                ))


def check_generated_frb(errors, pending):
    """Check flat API modules and free-function names, not signatures or wire code.

    Deliberately limited to this repository's top-level declarations. Codegen
    followed by a clean Git diff remains the authoritative consistency check.
    """
    modules = re.findall(r"^pub mod (\w+);", read("rust/src/api/mod.rs"), re.M)
    for module in modules:
        source = ROOT / "rust/src/api" / (module + ".rs")
        if not source.is_file():
            # POSIX separators keep the report stable across Linux CI and Windows.
            errors.append("missing Rust API source: " +
                          source.relative_to(ROOT).as_posix())
            continue
        generated = ROOT / "lib/src/rust/api" / (module + ".dart")
        if not generated.is_file():
            pending.append("missing generated FRB module: " +
                           generated.relative_to(ROOT).as_posix())
            continue
        # Discard generated comments so a mention of a function cannot pass.
        dart = re.sub(r"//[^\n]*|/\*.*?\*/", "", generated.read_text(encoding="utf-8"),
                      flags=re.S)
        rust = source.read_text(encoding="utf-8")
        functions = re.finditer(
            r"((?:^#\[[^\n]*\][^\n]*\n)*)^pub (?:async )?fn (\w+)\s*\(",
            rust, re.M,
        )
        for function in functions:
            attributes, name = function.groups()
            # Init functions are called through RustLib, not public wrappers.
            if re.search(r"\bfrb\(\s*(?:init|ignore)\s*\)", attributes):
                continue
            parts = name.split("_")
            wrapper = parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])
            if not re.search(r"^\S[^\n]*\b" + re.escape(wrapper) +
                             r"\s*\([^;]*?=>", dart, re.M):
                pending.append("missing generated FRB function: {}.{}".format(
                    module, wrapper,
                ))


def check_locks(errors, pending):
    # Only handles the repository's simple direct-dependency manifest syntax.
    manifest = read("pubspec.yaml")
    lock = read("pubspec.lock")
    locked = set(re.findall(r"^  ([\w-]+):\s*$", lock, re.M))
    active = False
    for line in manifest.splitlines():
        if re.match(r"^\w", line):
            active = line in ("dependencies:", "dev_dependencies:")
        match = re.match(r"^  ([\w-]+):", line) if active else None
        if match and match.group(1) not in locked:
            pending.append("Dart dependency absent from lock: " + match.group(1))
    for url in re.findall(r'^\s+url:\s*["\']?([^"\'\s]+)', lock, re.M):
        if url.rstrip("/") != "https://pub.dev":
            errors.append("pubspec.lock uses non-official hosted source")

    cargo_lock = read("rust/Cargo.lock")
    cargo_locked = set(re.findall(r'^name = "([^"]+)"', cargo_lock, re.M))
    active = False
    for line in read("rust/Cargo.toml").splitlines():
        if line.startswith("["):
            active = line in ("[dependencies]", "[dev-dependencies]")
        match = re.match(r"^([\w-]+)\s*=", line) if active else None
        if match and match.group(1) not in cargo_locked:
            pending.append("Rust dependency absent from lock: " + match.group(1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-pending-generation", action="store_true")
    options = parser.parse_args()
    errors, pending = [], []
    check_l10n(errors)
    if not errors:
        check_generated_l10n(pending)
    check_imports(errors, pending)
    check_generated_frb(errors, pending)
    check_locks(errors, pending)
    for message in errors:
        print("ERROR: " + message)
    for message in sorted(set(pending)):
        print("PENDING: " + message)
    failed = bool(errors) or (bool(pending) and not options.allow_pending_generation)
    if failed:
        print("FAIL: source checks found unresolved items; this is not a compiler.")
    elif pending:
        print("PARTIAL: source checks passed; generation/locks remain pending.")
    else:
        print("PASS: source checks only; compilation/tests still required.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
