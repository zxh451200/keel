#!/usr/bin/env python3
"""Check a trusted SignTool report against candidate bytes, not publisher identity."""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re

from collect_signature_evidence import digest, inventory, plain


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate report key")
        result[key] = value
    return result


def positive_id(value) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*", value) is not None


def report_time(value) -> datetime:
    if (not isinstance(value, str) or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
            r"(?:\.[0-9]{1,6})?(?:Z|\+00:00)", value)):
        raise ValueError("invalid report UTC timestamp")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("invalid report UTC timestamp") from error


def verify(root: Path, report_path: Path, expected_commit: str,
           expected_run_id: str, expected_run_attempt: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", expected_commit):
        raise ValueError("expected commit must be a full Git object ID")
    if not positive_id(expected_run_id) or not positive_id(expected_run_attempt):
        raise ValueError("expected run identity must use positive decimal IDs")
    plain(report_path)
    if not report_path.is_file() or report_path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("report must be a bounded regular file")
    report = json.loads(
        report_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object,
    )
    if (not isinstance(report, dict) or type(report.get("schema")) is not int
            or report["schema"] != 1 or report.get("status") != "PASS"
            or report.get("commit") != expected_commit):
        raise ValueError("report status, schema or commit mismatch")
    if (not positive_id(report.get("run_id"))
            or not positive_id(report.get("run_attempt"))
            or report["run_id"] != expected_run_id
            or report["run_attempt"] != expected_run_attempt):
        raise ValueError("report run identity mismatch")
    started = report_time(report.get("started_utc"))
    finished = report_time(report.get("finished_utc"))
    if started > finished:
        raise ValueError("report time order mismatch")
    if finished > datetime.now(timezone.utc) + timedelta(minutes=5):
        raise ValueError("report timestamp is in the future")
    tool = report.get("tool")
    if (not isinstance(tool, dict) or not isinstance(tool.get("path"), str)
            or not tool["path"] or not isinstance(tool.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", tool["sha256"])):
        raise ValueError("missing tool identity")
    files = {path.relative_to(root).as_posix(): path for path in inventory(root)}
    rows = report.get("files")
    if not isinstance(rows, list) or len(rows) != len(files):
        raise ValueError("signature report coverage mismatch")
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise ValueError("invalid signature report entry")
        name = row["path"]
        if name not in files or name in seen:
            raise ValueError("unknown or duplicate signature target")
        seen.add(name)
        command = row.get("command")
        if (row.get("status") != "PASS" or type(row.get("exit_code")) is not int
                or row["exit_code"] != 0 or not isinstance(command, list)
                or len(command) != 7 or command[0] != tool["path"]
                or command[1:6] != ["verify", "/pa", "/all", "/v", "/tw"]
                or not isinstance(command[6], str) or not command[6]):
            raise ValueError("signature verification did not pass with required flags")
        current = digest(files[name])
        if row.get("sha256") != current or row.get("sha256_after") != current:
            raise ValueError("signature target bytes changed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    args = parser.parse_args()
    try:
        verify(args.root.absolute(), args.report.absolute(), args.commit,
               args.run_id, args.run_attempt)
    except (OSError, ValueError) as error:
        print("FAIL:", error)
        return 1
    print("PASS: trusted signature report matches candidate bytes; publisher policy not evaluated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
