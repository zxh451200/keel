import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class SecurityTests(unittest.TestCase):
    def execute(self, mode="ok", optional=True, strict=True):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "scripts").mkdir()
        (root / "rust").mkdir()
        (root / "pubspec.lock").write_text('  url: "https://pub.dev"\n')
        for name in ("security_check.py", "security-check.sh", "advisory_provenance.py"):
            shutil.copyfile(SCRIPTS / name, root / "scripts" / name)
        tools = root / "tools"
        tools.mkdir()
        # python3 binds to the running interpreter: the WindowsApps alias and
        # other store shims cannot be exec'd from MSYS bash. A bash stub (not an
        # NTFS symlink) also avoids Windows resolving DLLs against the link's
        # directory (0xC0000135 -> silent exit 127) when the interpreter lives
        # elsewhere; exec'ing the real path keeps the DLL search on its own dir.
        python3 = tools / "python3"
        with open(python3, "w", newline="\n") as stream:
            stream.write("#!/bin/bash\nexec " + Path(sys.executable).as_posix() + ' "$@"\n')
        python3.chmod(0o755)
        for name in ("bash", "dirname"):
            (tools / name).symlink_to(shutil.which(name))
        # Tool stubs follow the host shell: bash scripts on POSIX, batch files on
        # Windows (shutil.which/PATHEXT and capture() cannot exec bare bash
        # scripts there). Behavior mirrors the POSIX stub in both modes.
        if os.name == "nt":
            stub = (
                "@echo off\r\n"
                'set "ARGS=%*"\r\n'
                # Substring probes via cmd variable replacement: the fixture PATH
                # holds only the tools dir, so findstr cannot be assumed.
                'if not "%ARGS:--version=%"=="%ARGS%" (echo fixture 1.0& exit /b 0)\r\n'
                'if not "%ARGS:version=%"=="%ARGS%" (echo fixture 1.0& exit /b 0)\r\n'
                'if /i "%~1"=="install" (\r\n'
                "  echo cargo-license v0.7.0:\r\n"
                "  echo     cargo-license\r\n"
                "  exit /b 0\r\n"
                ")\r\n"
                'if /i "%~n0"=="osv-scanner" if not "%~1"=="scan" exit /b 64\r\n'
                'if /i "%~n0"=="gitleaks" if not "%~1"=="dir" exit /b 64\r\n'
            )
            mode_body = {
                "fail": "echo scanner failure\r\nexit /b 2\r\n",
                "unknown": "echo UNSURE result\r\nexit /b 0\r\n",
                "partial": 'if not "%ARGS:--no-fetch=%"=="%ARGS%" exit /b 0\r\necho failed to fetch\r\nexit /b 2\r\n',
            }.get(mode, "echo fixture scan completed\r\nexit /b 0\r\n")
            stub += mode_body
        else:
            stub = "#!/bin/bash\nif [[ $* == *--version* || $* == version ]]; then printf 'fixture 1.0'; exit 0; fi\n"
            stub += "if [[ $* == 'install --list' ]]; then printf 'cargo-license v0.7.0:\n    cargo-license\n'; exit 0; fi\n"
            stub += 'case "${0##*/}" in\n'
            stub += 'osv-scanner) [[ "$*" == "scan source --lockfile=rust/Cargo.lock --lockfile=pubspec.lock --config="*" --format=json --output="* ]] || exit 64;;\n'
            stub += 'gitleaks) [[ "$*" == "dir . --redact --no-banner --max-target-megabytes 2" ]] || exit 64;;\nesac\n'
            if mode == "fail":
                stub += "printf 'scanner failure'; exit 2\n"
            elif mode == "unknown":
                stub += "printf 'UNSURE result'; exit 0\n"
            elif mode == "partial":
                stub += "if [[ $* == *--no-fetch* ]]; then exit 0; fi\nprintf 'failed to fetch'; exit 2\n"
            else:
                stub += "printf 'fixture scan completed'; exit 0\n"
        suffix = ".bat" if os.name == "nt" else ""
        for name in ("cargo", "cargo-license", "cargo-deny", "cargo-audit", "flutter") + (("osv-scanner", "gitleaks") if optional else ()):
            file = tools / (name + suffix)
            file.write_text(stub)
            file.chmod(0o755)
        env = dict(os.environ, PATH=str(tools), PYTHONDONTWRITEBYTECODE="1", GITHUB_OUTPUT=str(root / "step-output"))
        # Resolve bash from PATH (fixtures provide it) so the suite runs on
        # Linux CI and on Windows hosts with Git Bash alike.
        result = subprocess.run(["bash", str(root / "scripts/security-check.sh")] + (["--strict"] if strict else []),
                                env=env, capture_output=True, text=True, timeout=30)
        reports = list((root / "build/reports").glob("security-*/summary.json"))
        self.assertEqual(len(reports), 1, result.stderr)
        self.assertEqual((root / "step-output").read_text().strip(),
                         "summary_path=" + reports[0].as_posix())
        return result, json.loads(reports[0].read_text()), reports[0].parent

    def test_all_success_local(self):
        result, data, _ = self.execute(strict=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(data["status"], "PASS")
        self.assertEqual(data["commit"], "unavailable")
        self.assertTrue(all(c["started_at"] and c["ended_at"] for c in data["checks"]))

    def test_missing_required_in_strict(self):
        result, data, _ = self.execute(optional=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("MISSING", [c["status"] for c in data["checks"]])

    def test_local_optional_skip_is_not_full_pass(self):
        result, data, _ = self.execute(optional=False, strict=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(data["status"], "LOCAL_INCOMPLETE")

    def test_failure_retains_reports(self):
        result, data, reports = self.execute(mode="fail")
        self.assertEqual(result.returncode, 1)
        self.assertTrue((reports / "gitleaks.txt").is_file())
        self.assertTrue(all((reports / c["report"]).is_file() for c in data["checks"]))

    def test_unknown_never_passes(self):
        result, data, _ = self.execute(mode="unknown")
        self.assertEqual(result.returncode, 3)
        self.assertIn("UNKNOWN", [c["status"] for c in data["checks"]])

    def test_partial_cache_never_passes(self):
        result, data, reports = self.execute(mode="partial")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PARTIAL", [c["status"] for c in data["checks"]])
        self.assertTrue((reports / "audit-offline.txt").is_file())

    def test_unknown_database_blocks_strict_even_on_zero_exit(self):
        result, data, _ = self.execute()
        self.assertEqual(result.returncode, 3)
        self.assertEqual(data["status"], "INCOMPLETE")
        for check in data["checks"]:
            if check["name"] in ("audit", "deny-advisories", "osv"):
                self.assertEqual(check["status"], "UNKNOWN")
                self.assertEqual(check["exit_code"], 0)

    def test_report_parent_symlink_is_rejected(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "scripts").mkdir()
        (root / "scripts/security_check.py").write_bytes((SCRIPTS / "security_check.py").read_bytes())
        (root / "scripts/advisory_provenance.py").write_bytes((SCRIPTS / "advisory_provenance.py").read_bytes())
        (root / "pubspec.lock").write_text('  url: "https://pub.dev"\n')
        (root / "build").mkdir()
        outside = root / "outside"
        outside.mkdir()
        (root / "build/reports").symlink_to(outside, target_is_directory=True)
        result = subprocess.run([sys.executable, str(root / "scripts/security_check.py")],
                                cwd=root, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(outside.iterdir()))

    def test_timeout_keeps_partial_output(self):
        from unittest.mock import patch
        sys.path.insert(0, str(SCRIPTS))
        import security_check
        with patch.object(security_check.subprocess, "run", side_effect=
                          subprocess.TimeoutExpired(["scanner"], 600, output=b"partial finding")):
            code, output = security_check.capture(["scanner"], SCRIPTS)
        self.assertEqual(code, 124)
        self.assertIn("partial finding", output)
        self.assertIn("TimeoutExpired", output)
