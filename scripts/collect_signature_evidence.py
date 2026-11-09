#!/usr/bin/env python3
"""Collect SignTool verification evidence; this is not release approval."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import subprocess


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def plain(path: Path) -> None:
    for item in (path, *path.parents):
        info = item.lstat()
        if (stat.S_ISLNK(info.st_mode)
                or getattr(info, "st_file_attributes", 0) & 0x400):
            raise ValueError("symlink/reparse point rejected")


def inventory(root: Path) -> list[Path]:
    plain(root)
    if not root.is_dir():
        raise ValueError("root must be a directory")
    files = []
    pending = [root]
    while pending:
        for path in sorted(pending.pop().iterdir()):
            plain(path)
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                pending.append(path)
            elif not stat.S_ISREG(mode):
                raise ValueError("non-regular entry")
            elif path.suffix.lower() in {".exe", ".dll", ".msi"}:
                files.append(path)
    if not files:
        raise ValueError("no exe/dll/msi files found")
    return sorted(files)


def collect(root: Path, tool: Path) -> dict:
    report = {
        "schema": 1,
        "scope": "SignTool /pa /all /v /tw; publisher identity policy not evaluated",
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "commit": os.environ.get("GITHUB_SHA", "unknown"),
        "run_id": os.environ.get("GITHUB_RUN_ID", "unknown"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "unknown"),
        "status": "NOT RUN",
        "files": [],
    }
    try:
        files = inventory(root)
        if platform.system() != "Windows":
            report["reason"] = "Windows SignTool requires Windows"
            return report
        plain(tool)
        if not tool.is_file():
            raise ValueError("SignTool must be a regular file")
        report["tool"] = {"path": str(tool), "sha256": digest(tool)}
        report["status"] = "PASS"
        for path in files:
            before = digest(path)
            command = [str(tool), "verify", "/pa", "/all", "/v", "/tw", str(path)]
            row = {
                "path": path.relative_to(root).as_posix(),
                "sha256": before, "command": command, "status": "NOT RUN",
            }
            report["files"].append(row)
            try:
                result = subprocess.run(
                    command, capture_output=True, timeout=120, check=False,
                )
                row.update(
                    exit_code=result.returncode,
                    stdout_hex=result.stdout.hex(),
                    stderr_hex=result.stderr.hex(),
                    sha256_after=digest(path),
                )
                row["status"] = (
                    "PASS" if result.returncode == 0
                    and before == row["sha256_after"] else "FAIL"
                )
            except subprocess.TimeoutExpired:
                row.update(status="FAIL", reason="SignTool timed out")
            except OSError as error:
                row["reason"] = str(error)
            if row["status"] != "PASS":
                report["status"] = "FAIL"
        if inventory(root) != files:
            raise ValueError("signature target inventory changed")
        for row in report["files"]:
            if digest(root / row["path"]) != row["sha256"]:
                raise ValueError("target bytes changed during collection")
        if digest(tool) != report["tool"]["sha256"]:
            raise ValueError("SignTool bytes changed during collection")
    except (OSError, ValueError) as error:
        report["status"] = "FAIL" if report["files"] else "NOT RUN"
        report["reason"] = str(error)
    finally:
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--signtool", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.absolute()
    output = args.output.absolute()
    try:
        plain(output.parent)
        if output.resolve() == root.resolve() or root.resolve() in output.resolve().parents:
            raise ValueError("report must be outside candidate root")
        if output.exists() or output.is_symlink():
            raise ValueError("report already exists")
        report = collect(root, args.signtool.absolute())
        with output.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    except (OSError, ValueError) as error:
        print("FAIL:", error)
        return 1
    print(report["status"])
    return {"PASS": 0, "FAIL": 1, "NOT RUN": 3}[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
