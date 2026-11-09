"""Observe actual RustSec snapshots. Integrity evidence, not attestations."""
from __future__ import annotations
import json
from pathlib import Path
import re

RUSTSEC_URL = "https://github.com/rustsec/advisory-db"


def observe(path: Path, capture) -> dict:
    result = {"path": str(path), "status": "unknown"}
    observations = {}
    for key, args in (
        ("url", ["remote", "get-url", "origin"]),
        ("revision", ["rev-parse", "HEAD"]),
        ("tree", ["rev-parse", "HEAD^{tree}"]),
        ("dirty", ["status", "--porcelain", "--untracked-files=all"]),
    ):
        code, output = capture(["git", "-C", str(path), *args], path)
        observations[key] = {"exit_code": code, "output": output.strip()}
    result["observations"] = observations
    result.update({key: value["output"] for key, value in observations.items()})
    if (all(v["exit_code"] == 0 for v in observations.values())
            and re.sub(r"\.git$", "", result["url"]) == RUSTSEC_URL
            and all(re.fullmatch(r"[0-9a-f]{40}", result[k]) for k in ("revision", "tree"))
            and not result["dirty"]):
        result["status"] = "verified"
    return result


def prepare(root: Path, reports: Path, capture) -> dict:
    """Fresh per-run cargo-deny cache, preserving all project policies."""
    result = {"status": "unknown", "reason": "RustSec preparation unavailable"}
    try:
        text = (root / "rust/deny.toml").read_text(encoding="utf-8")
        section = re.search(r"(?ms)^\[advisories\]\s*\n(.*?)(?=^\[|\Z)", text)
        if not section or not re.search(
                r'^db-urls\s*=\s*\["https://github.com/rustsec/advisory-db"\]\s*$',
                section[1], re.M):
            raise ValueError("unsupported RustSec URL configuration")
        cache = reports / "rustsec-cache"
        body, count = re.subn(r'(?m)^db-path\s*=.*$',
                             lambda _: "db-path = " + json.dumps(cache.as_posix()), section[1])
        if count != 1:
            raise ValueError("expected explicit advisories db-path")
        text = text[:section.start(1)] + body + text[section.end(1):]
        config = reports / "deny-snapshot.toml"
        config.write_text(text, encoding="utf-8")
        result["config"] = str(config)
        command = ["cargo", "deny", "--config", str(config), "fetch", "db"]
        code, output = capture(command, root / "rust")
        result["fetch"] = {"command": command, "exit_code": code, "output": output}
        candidates = [p.parent for p in cache.rglob(".git") if p.is_dir()]
        if code != 0 or len(candidates) != 1:
            raise ValueError("online RustSec fetch failed or database path ambiguous")
        result["before"] = observe(candidates[0], capture)
        result["status"] = result["before"]["status"]
    except (OSError, ValueError) as error:
        result["reason"] = str(error)
    return result


def finish(snapshot: dict, capture) -> dict:
    if "before" in snapshot:
        snapshot["after"] = observe(Path(snapshot["before"]["path"]), capture)
        if snapshot["before"] != snapshot["after"]:
            snapshot["status"] = "unknown"
            snapshot["reason"] = "RustSec snapshot changed during scanning"
    return snapshot


def validate(snapshot: dict) -> str:
    if snapshot.get("status") != "verified" or snapshot.get("fetch", {}).get("exit_code") != 0:
        raise ValueError("unverified/offline RustSec database")
    before, after = snapshot.get("before", {}), snapshot.get("after", {})
    if before != after or before.get("status") != "verified":
        raise ValueError("RustSec snapshot mismatch")
    observations = before.get("observations", {})
    for key in ("url", "revision", "tree", "dirty"):
        item = observations.get(key, {})
        if item.get("exit_code") != 0 or item.get("output") != before.get(key):
            raise ValueError("missing RustSec git observation")
    if (re.sub(r"\.git$", "", before["url"]) != RUSTSEC_URL or before["dirty"]
            or any(not re.fullmatch(r"[0-9a-f]{40}", before[k]) for k in ("revision", "tree"))):
        raise ValueError("invalid RustSec source/revision")
    return before["revision"]
