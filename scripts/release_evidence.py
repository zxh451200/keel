#!/usr/bin/env python3
"""Create deterministic, offline release evidence for a built artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import os
import shutil
import stat
import unicodedata
import subprocess
from pathlib import Path


def load_json(path: Path) -> object:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def run_version(command: list[str]) -> str:
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


REQUIRED_FILES = ("LICENSE", "THIRD_PARTY_NOTICES", "CHANGELOG.md", "data/flutter_assets/NOTICES.Z")
EVIDENCE_FILES = {"SHA256SUMS", "SBOM.spdx.json", "build-info.json", "EVIDENCE_SHA256SUMS"}
PROJECT_ROOT = Path(__file__).resolve().parents[1]


def safe_name(name: str) -> str:
    parts = name.split("/")
    if (not name or any(p in ("", ".", "..") or p.endswith((" ", ".")) for p in parts)
            or any(ord(c) < 32 or ord(c) == 127 or c in '\\:<>"|?*' for c in name)
            or any(re.fullmatch(r"(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?",
                                p, re.I) for p in parts)):
        raise ValueError(f"unsafe release path: {name!r}")
    return unicodedata.normalize("NFC", name).casefold()


def relative_files(root: Path, exclude_evidence: bool = True) -> list[Path]:
    # Do not resolve before checking: that would hide symlink ancestors.
    if any(p.is_symlink() for p in (root, *root.parents)) or not root.is_dir():
        raise ValueError("release root must be a real directory without symlink ancestors")
    files, seen = [], set()
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        key = safe_name(name)
        if key in seen:
            raise ValueError(f"conflicting path: {name}")
        seen.add(key)
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise ValueError(f"non-regular release entry: {name}")
        if exclude_evidence and path.relative_to(root).parts[0] == "evidence":
            continue
        if stat.S_ISREG(mode):
            files.append(path)
    return files


def write_manifest(path: Path, entries: list[tuple[str, str]]) -> None:
    path.write_text("".join(f"{digest}  {name}\n" for name, digest in entries), encoding="utf-8")


def write_zip_hash(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise ValueError("ZIP must be a regular file")
    safe_name(path.name)
    sidecar = path.with_name(path.name + ".sha256")
    if sidecar.is_symlink():
        raise ValueError("ZIP hash sidecar must not be a symlink")
    write_manifest(sidecar, [(path.name, sha256(path))])
    return sidecar


def bundle_scan(root: Path, summary_path: Path | None) -> dict:
    """Copy the explicit invocation's bytes, including failed diagnostic reports."""
    result = {"summary": None, "reports": {}, "errors": [], "database_versions": {}}
    destination = root / "security-scan"
    if destination.is_symlink():
        raise ValueError("security-scan directory must not be a symlink")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError("security-scan path must be a directory")
        shutil.rmtree(destination)
    if summary_path is None:
        result["errors"].append("scan summary unavailable")
        return result
    destination.mkdir(exist_ok=True)

    def copy(source: Path, target: Path) -> None:
        if (any(p.is_symlink() for p in (source, *source.parents)) or not source.is_file()):
            raise ValueError("scan input must be a regular file without symlink ancestors")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())

    copy(summary_path, destination / "summary.json")
    result["summary"] = "security-scan/summary.json"
    result["summary_name"] = summary_path.name
    try:
        summary = load_json(destination / "summary.json")
        if not isinstance(summary, dict):
            raise ValueError("scan summary must be an object")
        checks = summary.get("checks", [])
        if not isinstance(checks, list) or any(not isinstance(c, dict) for c in checks):
            raise ValueError("invalid scan checks")
        wanted = dict(summary.get("artifacts", {}))
        for check in checks:
            if check.get("name") in ("audit", "deny-advisories", "osv"):
                result["database_versions"][check["name"]] = check.get("database_version", "unknown")
            for key in ("report", "database_report"):
                if check.get(key):
                    name, digest = check[key], check.get(key + "_sha256")
                    if name in wanted and wanted[name] != digest:
                        raise ValueError("conflicting scan report digest")
                    wanted[name] = digest
        for name, digest in wanted.items():
            try:
                safe_name(name)
                if "/" in name or name == "summary.json":
                    raise ValueError("scan report must have a unique flat name")
                target = destination / "reports" / name
                copy(summary_path.parent / name, target)
                result["reports"][name] = target.relative_to(root).as_posix()
                if sha256(target) != digest:
                    raise ValueError("scan report checksum mismatch: " + name)
            except (OSError, ValueError) as error:
                result["errors"].append(str(error))
    except (OSError, ValueError, TypeError) as error:
        result["errors"].append(str(error))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    parser.add_argument("--hash-zip", type=Path, help="write external ZIP .sha256 after packaging")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--commit")
    parser.add_argument("--cargo-metadata", type=Path)
    parser.add_argument("--dart-deps", type=Path)
    parser.add_argument("--scan-summary", type=Path, help="existing security summary to bind by hash")
    args = parser.parse_args()

    if args.hash_zip:
        if any((args.root, args.output, args.version, args.commit, args.cargo_metadata, args.dart_deps, args.scan_summary)):
            parser.error("--hash-zip must be used alone")
        write_zip_hash(args.hash_zip)
        return 0
    if not all((args.root, args.output, args.version, args.commit, args.cargo_metadata, args.dart_deps)):
        parser.error("provide root/output/version/commit/cargo-metadata/dart-deps")
    root = args.root.absolute()
    output = args.output.absolute()
    if output != root / "evidence":
        raise ValueError("--output must be <root>/evidence")
    relative_files(root)
    if output.exists() and any(p.name not in EVIDENCE_FILES for p in output.iterdir()):
        raise ValueError("unexpected old evidence entry")
    required_files = (
        root / "LICENSE",
        root / "THIRD_PARTY_NOTICES",
        root / "CHANGELOG.md",
        root / "data/flutter_assets/NOTICES.Z",
    )
    missing = [str(path.relative_to(root)) for path in required_files if not path.is_file()]
    if missing:
        raise SystemExit("missing release files: " + ", ".join(missing))
    output.mkdir(parents=True, exist_ok=True)

    scan_evidence = bundle_scan(root, args.scan_summary)
    for lock_name in ("rust/Cargo.lock", "pubspec.lock"):
        lock_path = PROJECT_ROOT / lock_name
        if lock_path.is_file():
            target = root / "security-scan/locks" / lock_name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(lock_path.read_bytes())
    files = relative_files(root)
    checksums = [(path.relative_to(root).as_posix(), sha256(path)) for path in files]
    (output / "SHA256SUMS").write_text(
        "".join(f"{digest}  {name}\n" for name, digest in checksums),
        encoding="utf-8",
    )

    spdx_files = [
        {
            "SPDXID": f"SPDXRef-File-{index}",
            "fileName": name,
            "checksums": [{"algorithm": "SHA256", "checksumValue": digest}],
        }
        for index, (name, digest) in enumerate(checksums, start=1)
    ]
    packages = [
        {
            "SPDXID": "SPDXRef-Package-Keel",
            "name": "keel",
            "versionInfo": args.version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
        }
    ]
    cargo_metadata = load_json(args.cargo_metadata)
    cargo_packages = cargo_metadata.get("packages", [])
    if not isinstance(cargo_packages, list):
        raise ValueError("Cargo metadata packages must be a list")
    for package in cargo_packages:
        if not isinstance(package, dict) or not isinstance(package.get("name"), str) or not isinstance(package.get("version"), str):
            raise ValueError("Cargo metadata package requires name and version")
        package_id = package.get("id") or (package["name"] + "@" + package["version"])
        if not isinstance(package_id, str):
            raise ValueError("Cargo metadata package id must be text")
        packages.append(
            {
                "SPDXID": "SPDXRef-Cargo-" + hashlib.sha256(package_id.encode()).hexdigest(),
                "name": package["name"],
                "versionInfo": package["version"],
                "downloadLocation": package.get("source") or "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": package.get("license") or "NOASSERTION",
                "licenseDeclared": package.get("license") or "NOASSERTION",
            }
        )
    dart_dependencies = load_json(args.dart_deps)
    dart_packages = dart_dependencies.get("packages", [])
    if not isinstance(dart_packages, list):
        raise ValueError("Dart dependency packages must be a list")
    for package in dart_packages:
        if not isinstance(package, dict) or not isinstance(package.get("name"), str) or not isinstance(package.get("version"), str):
            raise ValueError("Dart dependency package requires name and version")
        packages.append(
            {
                "SPDXID": "SPDXRef-Dart-" + hashlib.sha256((package["name"] + "@" + package["version"]).encode()).hexdigest(),
                "name": package["name"],
                "versionInfo": package["version"],
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
            }
        )

    sbom = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"keel-{args.version}",
        "documentNamespace": f"https://keel.invalid/spdx/{args.commit}",
        "creationInfo": {
            "created": "1970-01-01T00:00:00Z",
            "creators": ["Tool: scripts/release_evidence.py"],
        },
        "packages": packages,
        "files": spdx_files,
        "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                           "relatedSpdxElement": "SPDXRef-Package-Keel"}] + [
            {"spdxElementId": "SPDXRef-Package-Keel", "relationshipType": "DEPENDS_ON",
             "relatedSpdxElement": package["SPDXID"]} for package in packages[1:]
        ] + [
            {
                "spdxElementId": "SPDXRef-Package-Keel",
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": file_entry["SPDXID"],
            }
            for file_entry in spdx_files
        ],
    }
    (output / "SBOM.spdx.json").write_text(
        json.dumps(sbom, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    lock_hashes = {}
    for lock_name in ("rust/Cargo.lock", "pubspec.lock"):
        lock_path = PROJECT_ROOT / lock_name
        if lock_path.is_file():
            lock_hashes[lock_name] = sha256(lock_path)

    scan_hashes = {}
    if args.scan_summary:
        if args.scan_summary.is_symlink() or not args.scan_summary.is_file():
            raise ValueError("scan summary must be regular")
        scan_hashes[args.scan_summary.name] = sha256(root / scan_evidence["summary"])
    build_info = {
        "application": "keel",
        "version": args.version,
        "commit": args.commit,
        "platform": platform.platform(),
        "workflow": ".github/workflows/release.yml",
        "dependency_scope": "build dependency inventory; distribution and licenses require review",
        "run_id": os.environ.get("GITHUB_RUN_ID", "unavailable"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "unavailable"),
        "run_url": (os.environ.get("GITHUB_SERVER_URL", "https://github.com") + "/" +
                    os.environ.get("GITHUB_REPOSITORY", "unavailable") + "/actions/runs/" +
                    os.environ.get("GITHUB_RUN_ID", "unavailable")),
        "runner": os.environ.get("RUNNER_NAME", "unavailable"),
        "target_arch": os.environ.get("KEEL_TARGET_ARCH", "unavailable"),
        "scan_database_version": json.dumps(scan_evidence["database_versions"], sort_keys=True) if scan_evidence["database_versions"] else "unavailable",
        "scan_evidence": scan_evidence,
        "scan_report_sha256": scan_hashes,
        "rust_toolchain": (PROJECT_ROOT / "rust-toolchain.toml").read_text(encoding="utf-8").strip(),
        "rustc": run_version(["rustc", "-vV"]),
        "flutter": run_version(["flutter", "--version"]),
        "frb_codegen": run_version(["flutter_rust_bridge_codegen", "--version"]),
        "lock_sha256": lock_hashes,
        "evidence": [
            "evidence/SHA256SUMS",
            "evidence/SBOM.spdx.json",
            "evidence/build-info.json",
            "LICENSE",
            "THIRD_PARTY_NOTICES",
            "data/flutter_assets/NOTICES.Z",
        ],
    }
    (output / "build-info.json").write_text(
        json.dumps(build_info, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_manifest(output / "EVIDENCE_SHA256SUMS", [
        (name, sha256(output / name)) for name in sorted(EVIDENCE_FILES - {"EVIDENCE_SHA256SUMS"})
    ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
