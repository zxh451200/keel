"""Collect Windows PID, DPI and close observations; never award acceptance PASS."""
import argparse
import ctypes as c
from ctypes import wintypes as w
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

RUNNER = "FLUTTER_RUNNER_WIN32_WINDOW"


class WinAPI:
    def __init__(self):
        self.u = c.WinDLL("user32", use_last_error=True)
        self.callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        signatures = {
            "EnumWindows": ([self.callback, w.LPARAM], w.BOOL),
            "GetWindowThreadProcessId": ([w.HWND, c.POINTER(w.DWORD)], w.DWORD),
            "GetClassNameW": ([w.HWND, w.LPWSTR, c.c_int], c.c_int),
            "IsWindowVisible": ([w.HWND], w.BOOL),
            "GetWindowRect": ([w.HWND, c.POINTER(w.RECT)], w.BOOL),
            "GetDpiForWindow": ([w.HWND], w.UINT),
            "GetWindowDpiAwarenessContext": ([w.HWND], c.c_void_p),
            "GetAwarenessFromDpiAwarenessContext": ([c.c_void_p], c.c_int),
            "PostMessageW": ([w.HWND, w.UINT, w.WPARAM, w.LPARAM], w.BOOL),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.u, name)
            fn.argtypes, fn.restype = args, result

    def windows(self, pid):
        found = []

        @self.callback
        def visit(hwnd, unused):
            owner = w.DWORD()
            self.u.GetWindowThreadProcessId(hwnd, c.byref(owner))
            name = c.create_unicode_buffer(256)
            self.u.GetClassNameW(hwnd, name, len(name))
            if owner.value == pid and name.value == RUNNER and self.u.IsWindowVisible(hwnd):
                found.append(int(hwnd))
            return True

        if not self.u.EnumWindows(visit, 0):
            raise OSError("window enumeration failed")
        return found

    def sample(self, hwnd):
        rect = w.RECT()
        if not self.u.GetWindowRect(hwnd, c.byref(rect)):
            raise OSError("window sampling failed")
        dpi = int(self.u.GetDpiForWindow(hwnd))
        awareness = self.u.GetAwarenessFromDpiAwarenessContext(
            self.u.GetWindowDpiAwarenessContext(hwnd))
        if not dpi or awareness < 0:
            raise OSError("window DPI information unavailable")
        return {"hwnd": hwnd, "dpi": dpi, "awareness": awareness,
                "scale_percent": dpi * 100 / 96,
                "rect": [rect.left, rect.top, rect.right, rect.bottom]}

    def close(self, hwnd, pid):
        if self.windows(pid) != [hwnd]:
            raise OSError("window ownership changed or is ambiguous")
        if not self.u.PostMessageW(hwnd, 0x0010, 0, 0):
            raise OSError("WM_CLOSE could not be posted")


def child_env(directory):
    env = os.environ.copy()
    env["KEEL_DATA_DIR"] = str(directory)
    env.pop("KEEL_FRB_TEST_TOKEN", None)
    return env


def probe(exe, output, api, close=False, startup=15.0, observe=10.0,
          prepare=0.0, interval=0.25, launch=subprocess.Popen,
          clock=time.monotonic, sleep=time.sleep):
    for value in (startup, observe, interval, prepare):
        if not math.isfinite(value) or value < 0 or value > 3600:
            raise ValueError("invalid observation timing")
    if startup == 0 or observe == 0 or interval < 0.1:
        raise ValueError("invalid observation timing")
    exe = exe.resolve(strict=True)
    if not exe.is_file():
        raise ValueError("executable must be a regular file")
    output = output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    data = output / "data"
    data.mkdir()
    report = {
        "schema": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
        "status": "NOT_RUN", "samples": [], "close_requested": False,
        "data_dir": str(data), "pid": None, "exit_code": None,
        "acceptance": {"printing": "NOT_RUN", "visual_dpi": "NOT_RUN", "exit_guard": "NOT_RUN"},
        "limitations": [
            "Window presence does not prove readiness or Release mode.",
            "DPI API observations do not verify layout or accessibility.",
            "WM_CLOSE does not verify Alt+F4 or the exit guard.",
            "This tool does not initiate printing.",
            "Executable hash does not identify the complete Release bundle.",
        ],
    }
    process = None
    started = clock()
    try:
        digest = hashlib.sha256()
        with exe.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        report["artifact"] = {"executable": str(exe), "sha256": digest.hexdigest()}
        with (output / "stdout.log").open("xb") as stdout, (output / "stderr.log").open("xb") as stderr:
            process = launch([str(exe)], cwd=str(exe.parent), env=child_env(data),
                             stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, shell=False)
        report["pid"] = process.pid
        deadline = clock() + startup
        first_window = None
        while process.poll() is None:
            now = clock()
            windows = api.windows(process.pid)
            if len(windows) > 1:
                raise OSError("multiple runner windows; refusing to choose")
            if windows:
                if first_window is None:
                    first_window, deadline = now, now + prepare + observe
                report["samples"].append(dict(elapsed_s=now - started, **api.sample(windows[0])))
                if close and not report["close_requested"] and now - first_window >= prepare:
                    # Record the single attempt even if posting raises.
                    report["close_requested"] = True
                    api.close(windows[0], process.pid)
            if now >= deadline:
                break
            sleep(min(interval, deadline - now))
        report["exit_code"] = process.poll()
        report["status"] = ("OBSERVED_EXIT" if report["exit_code"] is not None else
                            "TIMEOUT_ALIVE" if first_window is not None else "STARTUP_TIMEOUT")
    except Exception as error:
        report["status"], report["error"] = "PROBE_ERROR", type(error).__name__
    finally:
        if process is not None:
            report["exit_code"] = process.poll()
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        report["elapsed_s"] = clock() - started
        temporary = output / "summary.json.tmp"
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(output / "summary.json")
    # Preserve evidence and application data, including when the process is alive.
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--close", action="store_true")
    parser.add_argument("--startup", type=float, default=15)
    parser.add_argument("--observe", type=float, default=10)
    parser.add_argument("--prepare", type=float, default=0)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("live probing requires Windows; mock tests support Linux")
    result = probe(args.exe, args.output, WinAPI(), args.close,
                   args.startup, args.observe, args.prepare)
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result["status"] == "OBSERVED_EXIT" and result["exit_code"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
