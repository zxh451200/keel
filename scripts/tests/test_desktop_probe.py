import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import desktop_probe as subject


class DesktopProbeTests(unittest.TestCase):
    def test_window_enumeration_filters_pid_class_and_visibility(self):
        api = subject.WinAPI.__new__(subject.WinAPI)
        api.callback = subject.c.CFUNCTYPE(subject.w.BOOL, subject.w.HWND, subject.w.LPARAM)
        api.u = Mock()
        def owner(hwnd, pointer):
            subject.c.cast(pointer, subject.c.POINTER(subject.w.DWORD))[0] = 99 if hwnd == 2 else 42
            return 1
        def class_name(hwnd, buffer, size):
            buffer.value = "OtherWindow" if hwnd == 3 else subject.RUNNER
            return len(buffer.value)
        def enumerate_windows(callback, unused):
            for hwnd in (1, 2, 3, 4):
                callback(hwnd, 0)
            return True
        api.u.GetWindowThreadProcessId.side_effect = owner
        api.u.GetClassNameW.side_effect = class_name
        api.u.IsWindowVisible.side_effect = lambda hwnd: hwnd != 4
        api.u.EnumWindows.side_effect = enumerate_windows
        self.assertEqual(api.windows(42), [1])

    def test_close_rechecks_window_ownership(self):
        api = subject.WinAPI.__new__(subject.WinAPI)
        api.u = Mock()
        api.windows = Mock(return_value=[102])
        with self.assertRaises(OSError):
            api.close(101, 42)
        api.u.PostMessageW.assert_not_called()

    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.root = Path(fixture.name)
        self.exe = self.root / "app.exe"
        self.exe.write_bytes(b"synthetic executable fixture")
        self.output = self.root / "observations"
        self.now = 0.0
        self.code = None
        self.process = Mock(pid=42)
        self.process.poll.side_effect = lambda: self.code
        self.launch = Mock(return_value=self.process)
        self.api = Mock()
        self.api.windows.return_value = [101]
        self.api.sample.return_value = {"hwnd": 101, "dpi": 144, "rect": [0, 0, 800, 600]}

    def sleep(self, seconds):
        self.now += seconds

    def run_probe(self, **kwargs):
        return subject.probe(
            self.exe, self.output, self.api, startup=0.5, observe=0.5,
            launch=self.launch, clock=lambda: self.now, sleep=self.sleep, **kwargs,
        )

    def test_timeout_retains_live_process_and_evidence(self):
        with patch.dict(os.environ, {"KEEL_DATA_DIR": "caller", "KEEL_FRB_TEST_TOKEN": "test-token"}):
            report = self.run_probe()
            self.assertEqual(os.environ["KEEL_DATA_DIR"], "caller")
        self.assertEqual(report["status"], "TIMEOUT_ALIVE")
        self.assertEqual(report["acceptance"]["visual_dpi"], "NOT_RUN")
        self.assertTrue((self.output / "data").is_dir())
        self.assertTrue((self.output / "stdout.log").is_file())
        self.assertEqual(json.loads((self.output / "summary.json").read_text()), report)
        self.assertEqual(report["artifact"]["sha256"], hashlib.sha256(self.exe.read_bytes()).hexdigest())
        options = self.launch.call_args.kwargs
        self.assertNotIn("KEEL_FRB_TEST_TOKEN", options["env"])
        self.assertEqual(options["env"]["KEEL_DATA_DIR"], str(self.output / "data"))
        self.assertFalse(options["shell"])
        self.process.kill.assert_not_called()
        self.process.terminate.assert_not_called()
        self.api.close.assert_not_called()

    def test_close_once_then_wait_for_actual_exit(self):
        def close(hwnd, pid):
            self.assertEqual((hwnd, pid), (101, 42))
            self.code = 0
        self.api.close.side_effect = close
        report = self.run_probe(close=True, prepare=0.25)
        self.assertEqual(report["status"], "OBSERVED_EXIT")
        self.assertEqual(report["exit_code"], 0)
        self.assertTrue(report["close_requested"])
        self.api.close.assert_called_once_with(101, 42)
        self.assertGreaterEqual(self.now, 0.25)
        self.assertEqual(set(report["acceptance"].values()), {"NOT_RUN"})

    def test_close_ack_does_not_imply_exit(self):
        report = self.run_probe(close=True)
        self.assertEqual(report["status"], "TIMEOUT_ALIVE")
        self.assertIsNone(report["exit_code"])
        self.api.close.assert_called_once()
        self.process.kill.assert_not_called()

    def test_no_window_does_not_send_close(self):
        self.api.windows.return_value = []
        report = self.run_probe(close=True)
        self.assertEqual(report["status"], "STARTUP_TIMEOUT")
        self.api.close.assert_not_called()

    def test_multiple_windows_refuses_to_choose(self):
        self.api.windows.return_value = [101, 102]
        report = self.run_probe(close=True)
        self.assertEqual(report["status"], "PROBE_ERROR")
        self.api.close.assert_not_called()
        self.process.kill.assert_not_called()

    def test_launch_error_leaves_report(self):
        self.launch.side_effect = OSError("private path")
        report = self.run_probe()
        self.assertEqual(report["status"], "PROBE_ERROR")
        self.assertEqual(report["error"], "OSError")
        self.assertNotIn("private path", json.dumps(report))
        self.assertTrue((self.output / "summary.json").is_file())

    def test_existing_output_and_invalid_timing_do_not_launch(self):
        for value in (float("nan"), float("inf"), -1, 3601):
            with self.assertRaises(ValueError):
                self.run_probe(interval=value)
        self.output.mkdir()
        with self.assertRaises(FileExistsError):
            self.run_probe()
        self.launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
