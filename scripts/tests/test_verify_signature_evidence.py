import copy
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collect_signature_evidence as collector
import verify_signature_evidence as subject


class VerifySignatureEvidenceTests(unittest.TestCase):
    def test_run_identity_is_bound(self):
        for field in ("run_id", "run_attempt"):
            for value in (None, "", "unknown", 1, True, "0", "01", "999999"):
                report = copy.deepcopy(self.report)
                report[field] = value
                self.write(report)
                with self.assertRaisesRegex(ValueError, "run identity"):
                    self.verify()

    def test_expected_identity_is_validated(self):
        for value in (None, "", True, 1, "0", "01", "-1", "１"):
            for run_id, attempt in ((value, "2"), ("123456", value)):
                with self.assertRaisesRegex(ValueError, "run identity"):
                    subject.verify(self.root, self.path, self.commit, run_id, attempt)

    def test_utc_timestamps_are_required(self):
        for field in ("started_utc", "finished_utc"):
            for value in (None, True, "", "2026-11-06", "2026-11-06T12:00:00",
                          "2026-11-06T12:00:00+01:00", "2026-02-30T12:00:00Z"):
                report = copy.deepcopy(self.report)
                report[field] = value
                self.write(report)
                with self.assertRaisesRegex(ValueError, "UTC timestamp"):
                    self.verify()
        self.assertEqual(subject.report_time("2000-01-01T00:00:00Z"),
                         datetime(2000, 1, 1, tzinfo=timezone.utc))

    def test_time_order_and_future_boundary(self):
        now = datetime(2026, 11, 6, tzinfo=timezone.utc)
        report = copy.deepcopy(self.report)
        report["started_utc"] = now.isoformat()
        with patch.object(subject, "datetime") as clock:
            clock.fromisoformat.side_effect = datetime.fromisoformat
            clock.now.return_value = now
            for delta, error in (
                (timedelta(microseconds=-1), "time order"),
                (timedelta(0), None), (timedelta(minutes=5), None),
                (timedelta(minutes=5, microseconds=1), "future"),
            ):
                report["finished_utc"] = (now + delta).isoformat()
                self.write(report)
                if error:
                    with self.assertRaisesRegex(ValueError, error):
                        self.verify()
                else:
                    self.verify()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "candidate"
        self.root.mkdir()
        self.target = self.root / "应用.exe"
        self.target.write_bytes(b"test fixture, not PE")
        self.tool = self.base / "signtool.exe"
        self.tool.write_bytes(b"tool fixture")
        self.commit = "a" * 40
        self.path = self.base / "report.json"
        self.run_id = "123456"
        self.run_attempt = "2"
        with patch.dict(os.environ, {
            "GITHUB_SHA": self.commit,
            "GITHUB_RUN_ID": self.run_id,
            "GITHUB_RUN_ATTEMPT": self.run_attempt,
        }):
            with patch.object(collector.platform, "platform", return_value="test-host"):
                with patch.object(collector.platform, "system", return_value="Windows"):
                    with patch.object(collector.subprocess, "run", return_value=
                                      subprocess.CompletedProcess([], 0, b"ok", b"")):
                        self.report = collector.collect(self.root, self.tool)
        self.write(self.report)

    def write(self, report):
        self.path.write_text(json.dumps(report), encoding="utf-8")

    def verify(self):
        subject.verify(self.root, self.path, self.commit, self.run_id, self.run_attempt)

    def test_collected_report_matches_candidate(self):
        self.verify()

    def test_payload_changes_invalidate_report(self):
        self.target.write_bytes(b"changed after verification")
        with self.assertRaisesRegex(ValueError, "bytes changed"):
            self.verify()

    def test_new_or_removed_binary_invalidates_coverage(self):
        extra = self.root / "extra.dll"
        extra.write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "coverage"):
            self.verify()
        extra.unlink()
        self.target.unlink()
        with self.assertRaises(ValueError):
            self.verify()

    def test_failed_unrun_or_wrong_commit_cannot_pass(self):
        for field, value in (
            ("status", "FAIL"), ("status", "NOT RUN"),
            ("commit", "b" * 40), ("schema", True),
        ):
            with self.subTest(field=field, value=value):
                report = copy.deepcopy(self.report)
                report[field] = value
                self.write(report)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_bad_entries_cannot_pass(self):
        for field, value in (
            ("status", "NOT RUN"), ("exit_code", 2), ("exit_code", False),
            ("path", "../escape.exe"), ("sha256_after", "0" * 64),
            ("command", [str(self.tool), "verify", "/pa", "/all", "/v", "wrong", "target"]),
        ):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report["files"][0][field] = value
                self.write(report)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_duplicate_targets_are_rejected(self):
        (self.root / "second.dll").write_bytes(b"second")
        report = copy.deepcopy(self.report)
        report["files"].append(copy.deepcopy(report["files"][0]))
        self.write(report)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.verify()

    def test_duplicate_json_keys_are_rejected(self):
        self.path.write_text('{"status":"FAIL","status":"PASS"}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.verify()

    def test_non_object_report_and_incomplete_commit_are_rejected(self):
        self.write([])
        with self.assertRaises(ValueError):
            self.verify()
        with self.assertRaises(ValueError):
            subject.verify(self.root, self.path, "unknown", self.run_id, self.run_attempt)
