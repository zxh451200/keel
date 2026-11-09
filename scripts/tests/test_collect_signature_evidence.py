from contextlib import redirect_stdout
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collect_signature_evidence as subject


class SignatureEvidenceTests(unittest.TestCase):
    def setUp(self):
        platform_description = patch.object(subject.platform, "platform", return_value="test-host")
        platform_description.start()
        self.addCleanup(platform_description.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "candidate"
        self.root.mkdir()
        self.target = self.root / "应用 sample.exe"
        self.target.write_bytes(b"fixture, not PE")
        self.tool = self.base / "signtool.exe"
        self.tool.write_bytes(b"mock tool")

    def collect(self, code=0, side_effect=None):
        result = subprocess.CompletedProcess([], code, b"output\xff", b"")
        with patch.object(subject.platform, "system", return_value="Windows"):
            with patch.object(subject.subprocess, "run", return_value=result,
                              side_effect=side_effect) as run:
                report = subject.collect(self.root, self.tool)
        return report, run

    def test_success_binds_command_hash_and_raw_output(self):
        report, run = self.collect()
        self.assertEqual(report["status"], "PASS")
        row = report["files"][0]
        self.assertEqual(row["sha256"], subject.digest(self.target))
        self.assertEqual(bytes.fromhex(row["stdout_hex"]), b"output\xff")
        self.assertEqual(run.call_args[0][0], [
            str(self.tool), "verify", "/pa", "/all", "/v", "/tw", str(self.target),
        ])

    def test_failure_and_warning_both_block(self):
        for code in (1, 2):
            self.assertEqual(self.collect(code)[0]["status"], "FAIL")

    def test_linux_never_invokes_tool(self):
        with patch.object(subject.platform, "system", return_value="Linux"):
            with patch.object(subject.subprocess, "run") as run:
                self.assertEqual(subject.collect(self.root, self.tool)["status"], "NOT RUN")
        run.assert_not_called()

    def test_empty_inventory_never_passes(self):
        self.target.unlink()
        report, run = self.collect()
        self.assertEqual(report["status"], "NOT RUN")
        run.assert_not_called()

    def test_timeout_blocks(self):
        report, _ = self.collect(side_effect=subprocess.TimeoutExpired("signtool", 120))
        self.assertEqual(report["status"], "FAIL")

    def test_mutated_target_or_tool_blocks(self):
        for changed in (self.target, self.tool):
            def mutate(*args, **kwargs):
                changed.write_bytes(changed.read_bytes() + b"changed")
                return subprocess.CompletedProcess([], 0, b"", b"")
            self.assertEqual(self.collect(side_effect=mutate)[0]["status"], "FAIL")

    def test_symlink_target_is_rejected(self):
        try:
            (self.root / "link.dll").symlink_to(self.target)
        except OSError:
            self.skipTest("symlinks unavailable")
        report, run = self.collect()
        self.assertEqual(report["status"], "NOT RUN")
        run.assert_not_called()

    def test_cli_rejects_inside_output_and_existing_report(self):
        for output in (self.root / "report.json", self.base / "existing.json"):
            if output.parent == self.base:
                output.write_text("original", encoding="utf-8")
            with patch.object(sys, "argv", [
                "collector", "--root", str(self.root), "--signtool", str(self.tool),
                "--output", str(output),
            ]), redirect_stdout(io.StringIO()):
                self.assertEqual(subject.main(), 1)
            if output.parent == self.base:
                self.assertEqual(output.read_text(encoding="utf-8"), "original")
            else:
                self.assertFalse(output.exists())
