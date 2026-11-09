#!/usr/bin/env python3
"""Read-only offline integrity checks; not full SPDX schema or release approval."""
from __future__ import annotations
import argparse
import json
import re
import zipfile
import stat
import tempfile
from pathlib import Path
from release_evidence import REQUIRED_FILES, EVIDENCE_FILES, relative_files, safe_name, sha256


def manifest(path: Path) -> dict[str, str]:
    result, seen = {}, set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise ValueError("invalid checksum line")
        digest, name = match.groups()
        key = safe_name(name)
        if key in seen:
            raise ValueError("duplicate/conflicting checksum path")
        seen.add(key)
        result[name] = digest
    if not result:
        raise ValueError("empty manifest")
    return result


def verify_scan(root: Path, info: dict) -> None:
    from advisory_provenance import validate
    evidence = info.get("scan_evidence", {})
    if not isinstance(evidence, dict) or evidence.get("errors") or not evidence.get("summary"):
        raise ValueError("missing/incomplete scan evidence")

    def bound_file(name):
        if not isinstance(name, str) or not name.startswith("security-scan/"):
            raise ValueError("invalid scan evidence path")
        safe_name(name)
        path = root / name
        current = root
        for part in Path(name).parts:
            current = current / part
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError("scan evidence path contains a symlink")
        if not path.is_file() or path.is_symlink():
            raise ValueError("missing scan evidence bytes")
        return path

    summary_path = bound_file(evidence["summary"])
    if info["scan_report_sha256"] != {evidence.get("summary_name"): sha256(summary_path)}:
        raise ValueError("scan summary hash mismatch")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    if (summary.get("schema") != 1 or summary.get("input_integrity") is not True or summary.get("strict") is not True
            or summary.get("status") != "PASS" or type(summary.get("exit_code")) is not int
            or summary["exit_code"] != 0):
        raise ValueError("scan was not a passing strict invocation")
    if (not re.fullmatch(r"[0-9a-f]{40}", info["commit"])
            or summary.get("commit") != info["commit"]):
        raise ValueError("scan commit mismatch")
    locks = info["lock_sha256"]
    if summary.get("lock_sha256") != locks or set(locks) != {"rust/Cargo.lock", "pubspec.lock"}:
        raise ValueError("scan lock inventory mismatch")
    for name, digest in locks.items():
        if sha256(bound_file("security-scan/locks/" + name)) != digest:
            raise ValueError("scan lock bytes mismatch")
    checks = summary.get("checks", [])
    required = {"rust-licenses", "deny-licenses", "deny-bans-sources", "deny-advisories",
                "audit", "dart-deps", "osv", "gitleaks", "hygiene"}
    if (not isinstance(checks, list) or any(not isinstance(c, dict) for c in checks)
            or len(checks) != len(required) or {c.get("name") for c in checks} != required):
        raise ValueError("incomplete/duplicate scan checks")
    wanted = dict(summary.get("artifacts", {}))
    databases = {}
    for check in checks:
        if check.get("status") != "PASS" or type(check.get("exit_code")) is not int or check["exit_code"] != 0:
            raise ValueError("scan check did not pass")
        if not check.get("version") or any(x in check["version"].lower() for x in ("unknown", "unavailable")):
            raise ValueError("unknown scan tool version")
        for key in ("report", "database_report"):
            if key == "database_report" and check["name"] not in ("audit", "deny-advisories"):
                continue
            name, digest = check.get(key), check.get(key + "_sha256")
            if not isinstance(name, str) or (name in wanted and wanted[name] != digest):
                raise ValueError("missing/conflicting scan report")
            wanted[name] = digest
        if check["name"] in ("audit", "deny-advisories", "osv"):
            databases[check["name"]] = check.get("database_version", "unknown")
    reports = evidence.get("reports", {})
    if set(reports) != set(wanted):
        raise ValueError("scan report coverage mismatch")
    for name, digest in wanted.items():
        if sha256(bound_file(reports[name])) != digest:
            raise ValueError("scan report bytes mismatch")
    for check in checks:
        if check["name"] in ("audit", "deny-advisories"):
            snapshot = json.loads(bound_file(reports[check["database_report"]]).read_text(encoding="utf-8"))
            revision = validate(snapshot)
            if revision != check["database_version"]:
                raise ValueError("RustSec revision mismatch")
            command = check.get("command", [])
            if check["name"] == "audit":
                if command != ["cargo", "audit", "--db", snapshot["before"]["path"], "--no-fetch"]:
                    raise ValueError("audit database command mismatch")
            elif command != ["cargo", "deny", "--config", snapshot["config"], "check", "--disable-fetch", "advisories"]:
                raise ValueError("deny database command mismatch")
    if databases != evidence.get("database_versions") or json.dumps(databases, sort_keys=True) != info["scan_database_version"]:
        raise ValueError("database evidence mismatch")
    # The implemented OSV online mode has no global snapshot version. A caller
    # supplying an arbitrary nonempty string cannot upgrade it to release proof.
    raise ValueError("OSV online API database snapshot is unknown; strict release blocked")


def verify(root: Path, strict: bool = False) -> None:
    root = root.absolute()
    files = relative_files(root, exclude_evidence=False)
    actual = {p.relative_to(root).as_posix() for p in files}
    evidence = root / "evidence"
    payload = manifest(evidence / "SHA256SUMS")
    outer = manifest(evidence / "EVIDENCE_SHA256SUMS")
    if set(outer) != EVIDENCE_FILES - {"EVIDENCE_SHA256SUMS"}:
        raise ValueError("evidence manifest coverage mismatch")
    if any(n.split("/")[0] == "evidence" for n in payload):
        raise ValueError("payload must exclude evidence")
    expected = set(payload) | {"evidence/" + n for n in EVIDENCE_FILES}
    if actual != expected or not set(REQUIRED_FILES) <= set(payload):
        raise ValueError("missing/extra release files or licenses")
    for name, digest in payload.items():
        if sha256(root / name) != digest:
            raise ValueError("payload checksum mismatch: " + name)
    for name, digest in outer.items():
        if sha256(evidence / name) != digest:
            raise ValueError("evidence checksum mismatch: " + name)
    info = json.loads((evidence / "build-info.json").read_text(encoding="utf-8"))
    keys = ("application", "version", "commit", "platform", "rustc", "flutter", "frb_codegen",
            "run_id", "run_attempt", "run_url", "runner", "target_arch", "scan_database_version")
    for key in keys:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError("missing metadata: " + key)
        if strict and any(x in value.lower() for x in ("unavailable", "unknown")):
            raise ValueError("unknown metadata: " + key)
    if not isinstance(info.get("lock_sha256"), dict):
        raise ValueError("missing lock hashes")
    scan_hashes = info.get("scan_report_sha256")
    if not isinstance(scan_hashes, dict):
        raise ValueError("missing scan hashes")
    for hashes in (info["lock_sha256"], scan_hashes):
        for name, digest in hashes.items():
            safe_name(name)
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError("invalid metadata hash: " + name)
    if strict and (not {"rust/Cargo.lock", "pubspec.lock"} <= info["lock_sha256"].keys()
                   or not info.get("scan_report_sha256")):
        raise ValueError("missing lock/scan evidence")
    if strict:
        verify_scan(root, info)
    sbom = json.loads((evidence / "SBOM.spdx.json").read_text(encoding="utf-8"))
    entries = [sbom] + sbom["packages"] + sbom["files"]
    ids = [entry["SPDXID"] for entry in entries]
    if len(set(ids)) != len(ids) or any(not re.fullmatch(r"SPDXRef-[A-Za-z0-9.-]+", i) for i in ids):
        raise ValueError("invalid/duplicate SPDX ID")
    if sbom.get("spdxVersion") != "SPDX-2.3":
        raise ValueError("unsupported SPDX version")
    describes = {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                 "relatedSpdxElement": "SPDXRef-Package-Keel"}
    if describes not in sbom["relationships"]:
        raise ValueError("missing DOCUMENT DESCRIBES")
    for relation in sbom["relationships"]:
        if relation["spdxElementId"] not in ids or relation["relatedSpdxElement"] not in ids:
            raise ValueError("dangling SPDX relationship")
    for package in sbom["packages"]:
        if package.get("filesAnalyzed") is not False:
            raise ValueError("file analysis not supported by this inventory")
    listed = {f["fileName"]: f["checksums"] for f in sbom["files"]}
    if len(listed) != len(sbom["files"]) or set(listed) != set(payload):
        raise ValueError("SPDX file coverage mismatch")
    for name, digest in payload.items():
        if listed[name] != [{"algorithm": "SHA256", "checksumValue": digest}]:
            raise ValueError("SPDX checksum mismatch")


def verify_zip(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError("ZIP must be regular")
    sidecar = path.with_name(path.name + ".sha256")
    if sidecar.is_symlink() or manifest(sidecar) != {path.name: sha256(path)}:
        raise ValueError("ZIP checksum mismatch")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not entries or len(entries) > 10000:
            raise ValueError("ZIP entry limit exceeded or empty archive")
        seen, directories = set(), set()
        total = 0
        for entry in entries:
            key = safe_name(entry.orig_filename)
            if entry.filename != entry.orig_filename or key in seen:
                raise ValueError("duplicate/conflicting ZIP path")
            parents = {safe_name(p.as_posix()) for p in Path(entry.filename).parents
                       if p.as_posix() != "."}
            if key in directories or parents & seen:
                raise ValueError("ZIP file/directory conflict")
            seen.add(key)
            directories.update(parents)
            mode = stat.S_IFMT(entry.external_attr >> 16)
            if entry.is_dir() or mode not in (0, stat.S_IFREG):
                raise ValueError("ZIP entries must be regular files")
            if entry.flag_bits & 1:
                raise ValueError("encrypted ZIP entries are unsupported")
            total += entry.file_size
            if entry.file_size > 1024 ** 3 or total > 4 * 1024 ** 3:
                raise ValueError("ZIP uncompressed size limit exceeded")
        with tempfile.TemporaryDirectory(prefix="keel-release-verify-") as temporary:
            root = Path(temporary)
            for entry in entries:
                target = root / entry.filename
                target.parent.mkdir(parents=True, exist_ok=True)
                written = 0
                with archive.open(entry) as source, target.open("xb") as destination:
                    while True:
                        chunk = source.read(min(1024 * 1024, entry.file_size - written + 1))
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > entry.file_size:
                            raise ValueError("ZIP entry exceeds declared size")
                        destination.write(chunk)
                if written != entry.file_size:
                    raise ValueError("ZIP entry size mismatch")
            verify(root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--zip", type=Path)
    args = parser.parse_args()
    if args.strict and not args.root:
        parser.error("--strict requires --root; ZIP digest alone cannot validate metadata")
    if not args.root and not args.zip:
        parser.error("provide --root or --zip")
    if args.root:
        verify(args.root, args.strict)
    if args.zip:
        verify_zip(args.zip)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
