#!/usr/bin/env python3
"""Build and measure the SQLite workload used by the grid POC.

This script measures the data/query side only. It deliberately does not claim
anything about Flutter widget rendering, virtualisation, clipboard handling,
or desktop memory usage.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import platform
import statistics
from contextlib import closing
import time
from pathlib import Path
from typing import Any


DEFAULT_COUNTS = (10_000, 100_000, 1_000_000)
PAGE_SIZE = 200


def parse_counts(value: str) -> tuple[int, ...]:
    counts = tuple(sorted({int(part) for part in value.split(",")}))
    if not counts or any(count <= 0 for count in counts):
        raise argparse.ArgumentTypeError("row counts must be positive integers")
    return counts


def prepare_database(path: Path, rows: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=NORMAL")
        connection.execute("PRAGMA temp_store=MEMORY")
        connection.execute("DROP TABLE IF EXISTS grid_poc_row")
        connection.execute(
            """
            CREATE TABLE grid_poc_row (
                id INTEGER PRIMARY KEY,
                at INTEGER NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                target TEXT NOT NULL,
                result TEXT NOT NULL
            )
            """
        )
        connection.execute(
            "CREATE INDEX idx_grid_poc_at_actor ON grid_poc_row (at DESC, actor ASC, id DESC)"
        )
        batch = []
        for row_id in range(1, rows + 1):
            batch.append(
                (
                    row_id,
                    row_id * 1000,
                    f"actor-{row_id % 1000:04d}",
                    ("read", "update", "export", "import")[row_id % 4],
                    f"target-{row_id % 10000:05d}",
                    "ok" if row_id % 17 else "failed",
                )
            )
            if len(batch) == 5000:
                connection.executemany(
                    "INSERT INTO grid_poc_row VALUES (?, ?, ?, ?, ?, ?)", batch
                )
                batch.clear()
        if batch:
            connection.executemany(
                "INSERT INTO grid_poc_row VALUES (?, ?, ?, ?, ?, ?)", batch
            )
        connection.commit()
        connection.execute("ANALYZE")
        connection.commit()


SELECT_ROWS = "SELECT id, at, actor, action, target, result FROM grid_poc_row"
ORDER = " ORDER BY at DESC, actor ASC, id DESC LIMIT ? OFFSET ?"


def fixture_row(row_id: int) -> tuple:
    return (row_id, row_id * 1000, f"actor-{row_id % 1000:04d}",
            ("read", "update", "export", "import")[row_id % 4],
            f"target-{row_id % 10000:05d}", "ok" if row_id % 17 else "failed")


def validate_result(name: str, actual: list[tuple], rows: int) -> None:
    if name == "filtered_count":
        expected = [(rows - rows // 17,)]
    elif name == "filtered_page":
        ids = [i for i in range(42, rows + 1, 1000) if i % 17]
        expected = [fixture_row(i) for i in reversed(ids[-PAGE_SIZE:])]
    else:
        offset = {"page_midpoint": rows // 2, "page_end": rows, "page_last": max(0, rows - 1)}[name]
        expected = [fixture_row(i) for i in range(rows - offset, max(0, rows - offset - PAGE_SIZE), -1)]
    if actual != expected:
        raise ValueError(f"incorrect {name}: expected {len(expected)} rows, got {len(actual)}")


def measure(path: Path, rows: int, repetitions: int = 5, cache_mode: str = "warm") -> dict[str, Any]:
    if rows <= 0 or repetitions <= 0 or cache_mode not in ("warm", "new-connection"):
        raise ValueError("invalid measurement parameters")
    queries = {
        "page_midpoint": (SELECT_ROWS + ORDER, (PAGE_SIZE, rows // 2)),
        "filtered_page": (SELECT_ROWS + " WHERE actor = ? AND result = ?" + ORDER,
                          ("actor-0042", "ok", PAGE_SIZE, 0)),
        "filtered_count": ("SELECT COUNT(*) FROM grid_poc_row WHERE result = ?", ("ok",)),
        "page_last": (SELECT_ROWS + ORDER, (PAGE_SIZE, rows - 1)),
        "page_end": (SELECT_ROWS + ORDER, (PAGE_SIZE, rows)),
    }
    result = {"rows": rows, "page_size": PAGE_SIZE, "repetitions": repetitions,
              "cache_mode": cache_mode, "os_cache": "uncontrolled; reconnect is not cold OS cache"}
    for name, (sql, parameters) in queries.items():
        samples, counted, returned = [], None, None
        connection = None
        try:
            if cache_mode == "warm":
                connection = sqlite3.connect(path)
                validate_result(name, connection.execute(sql, parameters).fetchall(), rows)
            for _ in range(repetitions):
                if cache_mode == "new-connection":
                    connection = sqlite3.connect(path)
                started = time.perf_counter()
                actual = connection.execute(sql, parameters).fetchall()
                elapsed = (time.perf_counter() - started) * 1000
                validate_result(name, actual, rows)  # correctness is outside timing
                returned = len(actual)
                if name == "filtered_count":
                    counted = actual[0][0]
                samples.append(elapsed)
                if cache_mode == "new-connection":
                    connection.close()
                    connection = None
        finally:
            if connection is not None:
                connection.close()
        result[name] = {"samples_ms": samples, "returned_rows": returned,
                        "min_ms": min(samples), "median_ms": statistics.median(samples),
                        "max_ms": max(samples), "mean_ms": statistics.mean(samples)}
        if counted is not None:
            result[name]["count_value"] = counted
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--database",
        type=Path,
        default=Path("build/grid-poc.sqlite3"),
        help="SQLite database to recreate and measure",
    )
    parser.add_argument(
        "--counts",
        type=parse_counts,
        default=DEFAULT_COUNTS,
        help="comma-separated row counts (default: 10000,100000,1000000)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="write JSON results to this path instead of stdout",
    )
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--cache-mode", choices=("warm", "new-connection"), default="warm")
    args = parser.parse_args()
    if args.repetitions <= 0:
        parser.error("--repetitions must be positive")

    results = {
        "schema": 2,
        "scenario": "synthetic-grid-poc",
        "environment": {"python": platform.python_version(), "sqlite": sqlite3.sqlite_version,
                        "system": platform.platform(), "machine": platform.machine(),
                        "processor": platform.processor()},
        "database": os.fspath(args.database),
        "page_size": PAGE_SIZE,
        "query_scope": "SQLite data/query workload only",
        "measurements": [],
    }
    for count in args.counts:
        prepare_database(args.database, count)
        results["measurements"].append(measure(args.database, count, args.repetitions, args.cache_mode))

    encoded = json.dumps(results, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
