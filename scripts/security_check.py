#!/usr/bin/env python3
"""Security scan control flow. Exit 0=local success, 1=failure, 3=incomplete.

No dependency installation. Per-run logs survive failure; strict mode requires all
checks, known tool versions and known advisory database versions.
Unknown database versions are recorded, not invented.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
from advisory_provenance import prepare, finish, validate


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def capture(command: list[str], cwd: Path) -> tuple[int, str]:
    cmd = command
    if os.name == "nt":
        resolved = shutil.which(command[0])
        if resolved and resolved.lower().endswith((".bat", ".cmd")):
            cmd = ["cmd", "/d", "/s", "/c", resolved, *command[1:]]
    try:
        result = subprocess.run(cmd, cwd=cwd, text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return 124, output + "\nTimeoutExpired"
    except OSError as error:
        return 127, type(error).__name__ + ": " + str(error)


def plain_directory(path: Path) -> None:
    for item in (path, *path.parents):
        info = item.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ValueError("report path must use real directories")


def plain_output(path: Path) -> None:
    plain_directory(path.parent)
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise ValueError("GITHUB_OUTPUT must be a regular file")


def hygiene(root: Path) -> str:
    text = (root / "pubspec.lock").read_text(encoding="utf-8")
    urls = re.findall(r'^\s+url:\s*(.+)$', text, re.M)
    if not urls or any(url.strip('"\' ') != "https://pub.dev" for url in urls):
        raise ValueError("lock sources missing or not pub.dev")
    if any(any(ord(c) < 32 or c in "\\:" for c in p.name) for p in root.iterdir()):
        raise ValueError("unsafe root entry")
    return "lock sources and root names checked"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    parent = root / "build/reports"
    parent.mkdir(parents=True, exist_ok=True)
    plain_directory(parent)
    reports = Path(tempfile.mkdtemp(prefix="security-", dir=parent))
    started = now()
    initial_commit_code, initial_commit = capture(["git", "rev-parse", "HEAD"], root)
    initial_locks = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                     for name in ("rust/Cargo.lock", "pubspec.lock") if (root / name).is_file()}
    checks = []
    snapshot = (prepare(root, reports, capture)
                if all(shutil.which(t) for t in ("git", "cargo", "cargo-deny"))
                else {"status": "unknown", "reason": "RustSec preparation tools missing"})
    specs = [
        ("rust-licenses", "cargo-license", ["cargo", "license"], root / "rust", False),
        ("deny-licenses", "cargo-deny", ["cargo", "deny", "check", "licenses"], root / "rust", False),
        ("deny-bans-sources", "cargo-deny", ["cargo", "deny", "check", "bans", "sources"], root / "rust", False),
        ("deny-advisories", "cargo-deny", ["cargo", "deny", "check", "advisories"], root / "rust", False),
        ("audit", "cargo-audit", ["cargo", "audit"], root / "rust", False),
        ("dart-deps", "flutter", ["flutter", "pub", "deps", "--style=list"], root, False),
        ("osv", "osv-scanner", ["osv-scanner", "scan", "source", "--lockfile=rust/Cargo.lock", "--lockfile=pubspec.lock",
                               "--config=" + str(root / ".osv-scanner.toml"), "--format=json",
                               "--output=" + str(reports / "osv-scan.json")], root, True),
        ("gitleaks", "gitleaks", ["gitleaks", "git", ".", "--redact"], root, True),
    ]
    git_ok = capture(["git", "rev-parse", "--is-inside-work-tree"], root)[0] == 0
    if not git_ok:
        # 无 Git 元数据时扫描工作区文件，而不是对空历史误报 PASS。
        specs[-1] = (
            "gitleaks",
            "gitleaks",
            ["gitleaks", "dir", ".", "--redact", "--no-banner", "--max-target-megabytes", "2"],
            root,
            True,
        )
    for name, tool, command, cwd, optional in specs:
        if name == "deny-advisories" and snapshot.get("status") == "verified":
            # 仅在 RustSec 快照真实观察到（verified）时才钉定检查；cargo-deny 0.20.x
            # 已移除 check --disable-fetch，用等价的全局 --offline（不拉取，只用快照 db-path）。
            help_text = capture(["cargo", "deny", "check", "--help"], cwd)[1]
            if "--disable-fetch" in help_text:
                command = ["cargo", "deny", "--config", snapshot["config"], "check", "--disable-fetch", "advisories"]
            else:
                command = ["cargo", "deny", "--offline", "--config", snapshot["config"], "check", "advisories"]
        if name == "audit" and snapshot.get("before"):
            command = ["cargo", "audit", "--db", snapshot["before"]["path"], "--no-fetch"]
        entry = {"name": name, "tool": tool, "started_at": now(), "version": "unavailable",
                 "database_version": "unknown", "exit_code": None, "status": "UNKNOWN", "command": command}
        output = "tool missing"
        if not shutil.which(tool) or not shutil.which(command[0]):
            entry["status"] = "SKIP" if optional and not args.strict else "MISSING"
        else:
            if tool == "cargo-license":
                version_code, version = capture(["cargo", "install", "--list"], cwd)
                match = re.search(r"^cargo-license v(\S+):", version, re.M)
                if not match:
                    # CARGO_HOME 可能指向与 PATH 上工具不同的安装目录；去掉该变量再探一次。
                    cargo_home_backup = os.environ.pop("CARGO_HOME", None)
                    try:
                        version_code, version = capture(["cargo", "install", "--list"], cwd)
                    finally:
                        if cargo_home_backup is not None:
                            os.environ["CARGO_HOME"] = cargo_home_backup
                    match = re.search(r"^cargo-license v(\S+):", version, re.M)
                version = "cargo-license " + match.group(1) if match else ""
            else:
                version_code, version = capture(
                    [tool, "version" if tool == "gitleaks" else "--version"], cwd
                )
            if version_code == 0 and version.strip():
                entry["version"] = version.strip()
            code, output = capture(command, cwd)
            entry["exit_code"] = code
            entry["status"] = "PASS" if code == 0 else "FAIL"
            if name == "gitleaks" and re.search(
                r"not a git repository|0 commits scanned", output, re.I
            ):
                entry["status"] = "FAIL"
            if code == 0 and (re.search(r"^(?:UNKNOWN|UNSURE|PARTIAL|SKIP)\b", output, re.M | re.I)
                              or entry["version"] == "unavailable"):
                entry["status"] = "UNKNOWN"
            # Keep original failure report, separate fallback report; never call cache PASS.
            if name == "audit" and "--no-fetch" not in command and code and re.search(r"fetch|connect|IO error", output, re.I):
                offline_code, offline = capture(["cargo", "audit", "--no-fetch"], cwd)
                (reports / "audit-offline.txt").write_text(offline, encoding="utf-8")
                entry["fallback_exit_code"] = offline_code
                entry["status"] = "PARTIAL" if offline_code == 0 else "FAIL"
            if (name == "deny-advisories" and code
                    and not re.search(r"unexpected argument|unrecognized", output, re.I)
                    and re.search(r"fetch|connect|unable to access", output, re.I)):
                entry["status"] = "UNSURE"
        if name in ("audit", "deny-advisories") and snapshot.get("status") == "verified":
            entry["database_version"] = snapshot["before"]["revision"]
        if name == "osv":
            entry["database_reason"] = "OSV online API exposes no global snapshot version; unknown blocks strict release"
        if (args.strict and name in ("deny-advisories", "audit", "osv")
                and entry["status"] == "PASS" and entry["database_version"] == "unknown"):
            entry["status"] = "UNKNOWN"
        log = reports / (name + ".txt")
        log.write_text(output, encoding="utf-8")
        entry.update(ended_at=now(), report=log.name, report_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
        checks.append(entry)
    snapshot = finish(snapshot, capture)
    try:
        revision = validate(snapshot)
    except ValueError:
        revision = "unknown"
    provenance = reports / "rustsec-provenance.json"
    provenance.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for entry in checks:
        if entry["name"] in ("audit", "deny-advisories"):
            entry["database_version"] = revision
            entry["database_report"] = provenance.name
            entry["database_report_sha256"] = hashlib.sha256(provenance.read_bytes()).hexdigest()
            if args.strict and revision == "unknown" and entry["status"] == "PASS":
                entry["status"] = "UNKNOWN"
    hygiene_entry = {"name": "hygiene", "started_at": now(), "version": "python-stdlib",
                     "database_version": "not-applicable"}
    try:
        output = hygiene(root)
        hygiene_entry.update(status="PASS", exit_code=0)
    except (OSError, ValueError) as error:
        output = str(error)
        hygiene_entry.update(status="FAIL", exit_code=1)
    log = reports / "hygiene.txt"
    log.write_text(output, encoding="utf-8")
    hygiene_entry.update(ended_at=now(), report=log.name, report_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
    checks.append(hygiene_entry)
    failed = any(c["status"] in ("FAIL", "MISSING") for c in checks)
    incomplete = any(c["status"] not in ("PASS", "SKIP") for c in checks)
    code = 1 if failed else 3 if incomplete else 0
    if args.strict and any(c["status"] != "PASS" for c in checks):
        code = code or 3
    commit_code, commit = capture(["git", "rev-parse", "HEAD"], root)
    artifacts = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in reports.iterdir() if p.is_file()}
    lock_hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                   for name in ("rust/Cargo.lock", "pubspec.lock") if (root / name).is_file()}
    input_integrity = (lock_hashes == initial_locks and commit_code == initial_commit_code
                       and commit.strip() == initial_commit.strip())
    if not input_integrity:
        code = code or 3
    summary = {"input_integrity": input_integrity, "artifacts": artifacts, "lock_sha256": lock_hashes, "schema": 1, "strict": args.strict, "started_at": started, "ended_at": now(),
               "commit": commit.strip() if commit_code == 0 else "unavailable",
               "candidate_sha256": os.environ.get("KEEL_CANDIDATE_SHA256", "unavailable"),
               "status": "PASS" if code == 0 and all(c["status"] == "PASS" for c in checks)
                         else "LOCAL_INCOMPLETE" if code == 0 else "FAIL" if failed else "INCOMPLETE",
               "exit_code": code, "checks": checks}
    (reports / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    summary_path = reports / "summary.json"
    # Explicit per-invocation handoff; never select a stale report by glob/mtime.
    if os.environ.get("GITHUB_OUTPUT"):
        output_path = Path(os.environ["GITHUB_OUTPUT"])
        plain_output(output_path)
        with output_path.open("a", encoding="utf-8") as stream:
            stream.write("summary_path=" + summary_path.as_posix() + "\n")
    print(str(summary_path))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
