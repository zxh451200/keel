import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_evidence as release
import verify_release_evidence as checker


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "release"
        self.root.mkdir()
        for name in release.REQUIRED_FILES + (".hidden", "keel.exe"):
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("fixture " + name)
        self.cargo = self.base / "cargo.json"
        self.dart = self.base / "dart.json"
        self.cargo.write_text(json.dumps({"packages": [{"name": "a_b", "version": "1.0.0+foo", "license": "MIT"}]}))
        self.dart.write_text('{"packages": []}')
        self.generate()

    def generate(self, summary=None):
        args = ["release_evidence.py", "--root", str(self.root), "--output", str(self.root / "evidence"),
                "--version", "0.1.0", "--commit", "abc", "--cargo-metadata", str(self.cargo),
                "--dart-deps", str(self.dart)]
        if summary is not None:
            args += ["--scan-summary", str(summary)]
        with patch.object(sys, "argv", args), patch.object(release, "run_version", return_value="fixture-version"):
            self.assertEqual(release.main(), 0)

    def rehash(self):
        output = self.root / "evidence"
        release.write_manifest(output / "EVIDENCE_SHA256SUMS", [
            (name, release.sha256(output / name)) for name in sorted(release.EVIDENCE_FILES - {"EVIDENCE_SHA256SUMS"})])

    def test_dependency_json_shape_is_rejected_without_traceback_primitives(self):
        self.cargo.write_text(json.dumps({"packages": [{"id": "only-id", "version": "1.0.0"}]}))
        with self.assertRaisesRegex(ValueError, "requires name and version"):
            self.generate()
        self.cargo.write_text(json.dumps({"packages": {"name": "not-a-list"}}))
        with self.assertRaisesRegex(ValueError, "packages must be a list"):
            self.generate()

    def test_dependency_json_root_must_be_object(self):
        self.dart.write_text('[]')
        with self.assertRaisesRegex(ValueError, "root must be an object"):
            self.generate()

    def test_repeat_generation_replaces_scan_snapshot(self):
        checker.verify(self.root)
        before = (self.root / "evidence/SHA256SUMS").read_bytes()
        self.generate()
        self.assertEqual(before, (self.root / "evidence/SHA256SUMS").read_bytes())
        self.assertIn(".hidden", checker.manifest(self.root / "evidence/SHA256SUMS"))
        checker.verify(self.root)

    def test_existing_security_scan_is_replaced_before_copy(self):
        scan = self.root / "security-scan"
        (scan / "stale.txt").write_text("stale")
        self.generate()
        self.assertFalse((scan / "stale.txt").exists())

    def test_payload_tamper(self):
        (self.root / "keel.exe").write_text("changed")
        with self.assertRaises(ValueError):
            checker.verify(self.root)

    def test_evidence_tamper(self):
        (self.root / "evidence/build-info.json").write_text("{}")
        with self.assertRaises(ValueError):
            checker.verify(self.root)

    def test_missing_extra_and_license(self):
        for name in ("keel.exe", "LICENSE"):
            file = self.root / name
            data = file.read_bytes()
            file.unlink()
            with self.assertRaises(ValueError):
                checker.verify(self.root)
            file.write_bytes(data)
        (self.root / "extra").write_text("extra")
        with self.assertRaises(ValueError):
            checker.verify(self.root)

    def test_symlink_and_conflict(self):
        link = self.root / "link"
        link.symlink_to(self.cargo)
        with self.assertRaises(ValueError):
            self.generate()
        with self.assertRaises(ValueError):
            checker.verify(self.root)
        link.unlink()
        if os.path.normcase("KEEL.EXE") == os.path.normcase("keel.exe"):
            # Case-insensitive filesystems (NTFS default) cannot host a
            # case-conflicting payload name: the write replaces keel.exe itself.
            self.skipTest("case-conflicting payload name unrepresentable here")
        (self.root / "KEEL.EXE").write_text("conflict")
        with self.assertRaises(ValueError):
            self.generate()

    def test_unsafe_and_duplicate_manifest(self):
        file = self.base / "manifest"
        for names in (("../escape",), ("/absolute",), ("a/./b",), ("one", "ONE"), ("one", "one")):
            file.write_text("".join("0" * 64 + "  " + n + "\n" for n in names))
            with self.assertRaises(ValueError):
                checker.manifest(file)

    def test_invalid_spdx_and_missing_metadata(self):
        file = self.root / "evidence/SBOM.spdx.json"
        original = file.read_text()
        sbom = json.loads(original)
        sbom["packages"][1]["SPDXID"] = "SPDXRef-invalid_id"
        file.write_text(json.dumps(sbom))
        self.rehash()
        with self.assertRaises(ValueError):
            checker.verify(self.root)
        file.write_text(original)
        info = self.root / "evidence/build-info.json"
        data = json.loads(info.read_text())
        del data["commit"]
        info.write_text(json.dumps(data))
        self.rehash()
        with self.assertRaises(ValueError):
            checker.verify(self.root)

    def test_unknown_strict_metadata(self):
        with self.assertRaises(ValueError):
            checker.verify(self.root, strict=True)

    def test_final_zip_digest(self):
        from package_release import package
        archive = self.base / "release.zip"
        package(self.root, archive)
        release.write_zip_hash(archive)
        checker.verify_zip(archive)
        with archive.open("ab") as stream:
            stream.write(b"tamper")
        with self.assertRaises(ValueError):
            checker.verify_zip(archive)

    def test_hash_shaped_metadata_without_bytes_is_rejected(self):
        info = self.root / "evidence/build-info.json"
        data = json.loads(info.read_text())
        for key in ("run_id", "run_attempt", "run_url", "runner", "target_arch", "scan_database_version"):
            data[key] = "fixture-only"
        data["lock_sha256"] = {"rust/Cargo.lock": "0" * 64, "pubspec.lock": "1" * 64}
        data["scan_report_sha256"] = {"fixture-summary.json": "2" * 64}
        info.write_text(json.dumps(data))
        self.rehash()
        with self.assertRaisesRegex(ValueError, "scan evidence"):
            checker.verify(self.root, strict=True)

    def test_extra_evidence_rejected(self):
        (self.root / "evidence/old-report").write_text("stale")
        with self.assertRaises(ValueError):
            self.generate()
        with self.assertRaises(ValueError):
            checker.verify(self.root)

    def test_scan_evidence_symlink_boundary_is_rejected(self):
        _, info = self.scan_fixture()
        reports = self.root / "security-scan/reports"
        target = reports / "audit.txt"
        saved = target.read_bytes()
        target.unlink()
        target.symlink_to(self.base / "outside-report")
        (self.base / "outside-report").write_bytes(saved)
        with self.assertRaisesRegex(ValueError, "symlink"):
            checker.verify_scan(self.root, info)

    def test_output_boundary_and_directory_symlink(self):
        with patch.object(sys, "argv", ["release_evidence.py", "--root", str(self.root),
             "--output", str(self.base / "outside"), "--version", "0.1", "--commit", "abc",
             "--cargo-metadata", str(self.cargo), "--dart-deps", str(self.dart)]):
            with self.assertRaises(ValueError):
                release.main()
        (self.root / "dir-link").symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(ValueError):
            checker.verify(self.root)

    def test_zip_cli_exclusive_and_success(self):
        from package_release import package
        archive = self.base / "fixture.zip"
        package(self.root, archive)
        with patch.object(sys, "argv", ["release_evidence.py", "--hash-zip", str(archive)]):
            self.assertEqual(release.main(), 0)
        checker.verify_zip(archive)
        with patch.object(sys, "argv", ["release_evidence.py", "--hash-zip", str(archive),
                                       "--scan-summary", str(self.cargo)]), patch("sys.stderr"):
            with self.assertRaises(SystemExit) as error:
                release.main()
            self.assertEqual(error.exception.code, 2)

    def test_zip_internal_tamper_with_recomputed_sidecar(self):
        import zipfile
        from package_release import package
        original = self.base / "original.zip"
        package(self.root, original)
        for changed in ("keel.exe", "evidence/build-info.json"):
            archive = self.base / "changed.zip"
            with zipfile.ZipFile(original) as source, zipfile.ZipFile(archive, "w") as target:
                for entry in source.infolist():
                    data = source.read(entry)
                    target.writestr(entry, b"tampered" if entry.filename == changed else data)
            release.write_zip_hash(archive)
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "checksum mismatch"):
                checker.verify_zip(archive)

    def test_zip_unsafe_entries_and_conflicts(self):
        import stat
        import warnings
        import zipfile
        fixtures = [
            [("../escape", b"x")], [("/absolute", b"x")],
            [("one", b"x"), ("ONE", b"x")],
            [("one", b"x"), ("one", b"x")],
            [("a", b"x"), ("a/b", b"x")],
            [("a/b", b"x"), ("A", b"x")],
            [("e\u0301", b"x"), ("\u00e9", b"x")],
            [("folder/", b"")],
        ]
        for mode in (stat.S_IFLNK, stat.S_IFIFO):
            entry = zipfile.ZipInfo("special")
            entry.create_system = 3
            entry.external_attr = (mode | 0o600) << 16
            fixtures.append([(entry, b"target")])
        for entries in fixtures:
            archive = self.base / "unsafe.zip"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(archive, "w") as stream:
                    for entry, data in entries:
                        stream.writestr(entry, data)
            release.write_zip_hash(archive)
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                checker.verify_zip(archive)
        self.assertFalse((self.base / "escape").exists())

    def test_zip_inventory_limits_precede_staging(self):
        import zipfile
        archive = self.base / "large.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            stream.writestr("fixture", b"x")
        release.write_zip_hash(archive)
        for count, size in ((10001, 1), (1, 1024 ** 3 + 1), (5, 1024 ** 3)):
            entries = [zipfile.ZipInfo("file-" + str(i)) for i in range(count)]
            for entry in entries:
                entry.file_size = size
            with patch.object(zipfile.ZipFile, "infolist", return_value=entries), \
                    patch.object(checker.tempfile, "TemporaryDirectory") as staging:
                with self.subTest(count=count, size=size), self.assertRaisesRegex(ValueError, "limit"):
                    checker.verify_zip(archive)
                staging.assert_not_called()

    def test_windows_unsafe_manifest_paths(self):
        for name in ("CON", "dir/NUL.txt", "COM1.log", "a?b", "a*b", "a<b", 'a"b', "a|b", "a\x7fb"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.safe_name(name)

    def test_invalid_metadata_hashes(self):
        info = self.root / "evidence/build-info.json"
        original = json.loads(info.read_text(encoding="utf-8"))
        for key in ("lock_sha256", "scan_report_sha256"):
            data = dict(original)
            data[key] = {"fixture": "not-a-hash"}
            info.write_text(json.dumps(data), encoding="utf-8")
            self.rehash()
            with self.subTest(key=key), self.assertRaises(ValueError):
                checker.verify(self.root)

    def test_strict_zip_alone_is_rejected(self):
        with patch.object(sys, "argv", ["verify_release_evidence.py", "--zip", "unused.zip", "--strict"]), patch("sys.stderr"):
            with self.assertRaises(SystemExit) as error:
                checker.main()
            self.assertEqual(error.exception.code, 2)

    def test_unicode_evidence_roundtrip(self):
        (self.root / "说明.txt").write_text("发行测试", encoding="utf-8")
        self.generate()
        checker.verify(self.root)

    def test_package_preserves_hidden_files_and_rejects_tamper(self):
        import package_release
        import zipfile
        archive = self.base / "candidate.zip"
        package_release.package(self.root, archive)
        with zipfile.ZipFile(archive) as stream:
            expected = {p.relative_to(self.root).as_posix(): p.read_bytes()
                        for p in release.relative_files(self.root, exclude_evidence=False)}
            self.assertEqual({n: stream.read(n) for n in stream.namelist()}, expected)
            self.assertIn(".hidden", stream.namelist())
        with self.assertRaises(ValueError):
            package_release.package(self.root, archive)
        with self.assertRaises(ValueError):
            package_release.package(self.root, self.root / "nested.zip")
        (self.root / "keel.exe").write_text("tamper")
        with self.assertRaises(ValueError):
            package_release.package(self.root, self.base / "tampered.zip")

    def scan_fixture(self):
        import advisory_provenance as provenance
        source = self.base / "scan"
        source.mkdir(exist_ok=True)
        values = {"origin": provenance.RUSTSEC_URL, "HEAD": "a" * 40,
                  "HEAD^{tree}": "b" * 40, "--untracked-files=all": ""}
        observed = provenance.observe(source / "database", lambda cmd, cwd: (0, values[cmd[-1]]))
        snapshot = {"status": "verified", "before": observed, "after": observed,
                    "config": "/fixture/deny.toml", "fetch": {"exit_code": 0}}
        database = source / "rustsec-provenance.json"
        database.write_text(json.dumps(snapshot))
        checks = []
        for name in ("rust-licenses", "deny-licenses", "deny-bans-sources", "deny-advisories",
                     "audit", "dart-deps", "osv", "gitleaks", "hygiene"):
            report = source / (name + ".txt")
            report.write_bytes(("fixture " + name + "\r\n").encode())
            check = {"name": name, "status": "PASS", "exit_code": 0, "version": "fixture 1",
                     "report": report.name, "report_sha256": release.sha256(report)}
            if name in ("audit", "deny-advisories"):
                check.update(database_version="a" * 40, database_report=database.name,
                             database_report_sha256=release.sha256(database))
                check["command"] = (["cargo", "audit", "--db", observed["path"], "--no-fetch"]
                                    if name == "audit" else ["cargo", "deny", "--config",
                                    snapshot["config"], "check", "--disable-fetch", "advisories"])
            if name == "osv":
                check["database_version"] = "invented-global-version"
            checks.append(check)
        locks = {name: release.sha256(Path(name)) for name in ("rust/Cargo.lock", "pubspec.lock")}
        summary = {"schema": 1, "input_integrity": True, "strict": True, "status": "PASS", "exit_code": 0,
                   "commit": "c" * 40, "checks": checks, "lock_sha256": locks}
        summary_path = source / "summary.json"
        summary_path.write_text(json.dumps(summary))
        self.generate(summary_path)
        info = json.loads((self.root / "evidence/build-info.json").read_text())
        info["commit"] = summary["commit"]
        return summary, info

    def replace_scan_summary(self, summary, info):
        path = self.root / info["scan_evidence"]["summary"]
        path.write_text(json.dumps(summary))
        info["scan_report_sha256"] = {info["scan_evidence"]["summary_name"]: release.sha256(path)}

    def test_online_osv_cannot_invent_database_version(self):
        _, info = self.scan_fixture()
        with self.assertRaisesRegex(ValueError, "OSV online API"):
            checker.verify_scan(self.root, info)

    def test_summary_status_strict_commit_and_completeness(self):
        summary, info = self.scan_fixture()
        import copy
        for key, value, reason in (("status", "FAIL", "strict invocation"),
                                   ("strict", False, "strict invocation"),
                                   ("exit_code", 3, "strict invocation"),
                                   ("commit", "d" * 40, "commit mismatch"),
                                   ("input_integrity", False, "strict invocation"),
                                   ("checks", summary["checks"][:-1], "scan checks"),
                                   ("checks", summary["checks"] + [summary["checks"][0]], "scan checks")):
            changed = copy.deepcopy(summary)
            changed[key] = value
            self.replace_scan_summary(changed, info)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, reason):
                checker.verify_scan(self.root, info)

    def test_report_and_lock_bytes_are_verified(self):
        _, info = self.scan_fixture()
        for name in ("security-scan/reports/audit.txt", "security-scan/locks/pubspec.lock"):
            path = self.root / name
            before = path.read_bytes()
            path.write_bytes(b"changed")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "bytes mismatch"):
                checker.verify_scan(self.root, info)
            path.write_bytes(before)
        info["scan_report_sha256"] = {"summary.json": "e" * 64}
        with self.assertRaisesRegex(ValueError, "summary hash mismatch"):
            checker.verify_scan(self.root, info)

    def test_database_provenance_and_command_must_match(self):
        summary, info = self.scan_fixture()
        summary["checks"][4]["command"] = ["cargo", "audit"]
        self.replace_scan_summary(summary, info)
        with self.assertRaisesRegex(ValueError, "database command mismatch"):
            checker.verify_scan(self.root, info)
        summary["checks"][4]["command"] = ["cargo", "audit", "--db", "/wrong", "--no-fetch"]
        self.replace_scan_summary(summary, info)
        with self.assertRaisesRegex(ValueError, "database command mismatch"):
            checker.verify_scan(self.root, info)

    def test_failed_scan_still_generates_diagnostic_evidence(self):
        summary, info = self.scan_fixture()
        source = self.base / "scan/summary.json"
        summary["status"] = "FAIL"
        summary["exit_code"] = 1
        source.write_text(json.dumps(summary))
        (source.parent / "audit.txt").write_bytes(b"tampered source")
        self.generate(source)
        checker.verify(self.root)
        info = json.loads((self.root / "evidence/build-info.json").read_text())
        self.assertTrue(info["scan_evidence"]["errors"])
        self.assertEqual((self.root / "security-scan/reports/audit.txt").read_bytes(), b"tampered source")
        self.assertNotEqual(info["scan_database_version"], "unavailable")
        with self.assertRaises(ValueError):
            checker.verify_scan(self.root, info)

    def test_scan_report_path_escape_is_diagnostic_and_blocks(self):
        summary, _ = self.scan_fixture()
        summary["checks"][0]["report"] = "../outside"
        source = self.base / "scan/summary.json"
        source.write_text(json.dumps(summary))
        self.generate(source)
        info = json.loads((self.root / "evidence/build-info.json").read_text())
        self.assertTrue(info["scan_evidence"]["errors"])
        self.assertFalse((self.root / "outside").exists())

    def test_workflow_evidence_commands_execute_and_strict_blocks(self):
        # Execute the actual workflow bash blocks against an isolated fixture repo.
        import os
        import shutil
        import subprocess
        if shutil.which("bash") is None:
            self.skipTest("bash unavailable on PATH")
        repository = Path(__file__).resolve().parents[2]
        workspace = self.base / "fixture-repository"
        workspace.mkdir()
        scripts = workspace / "scripts"
        scripts.mkdir()
        for name in ("release_evidence.py", "verify_release_evidence.py", "package_release.py", "advisory_provenance.py"):
            shutil.copyfile(repository / "scripts" / name, scripts / name)
        (workspace / "rust").mkdir()
        (workspace / "rust/Cargo.lock").write_text("fixture")
        (workspace / "pubspec.lock").write_text("fixture")
        (workspace / "rust-toolchain.toml").write_text("fixture")
        candidate = workspace / "build/release/keel-windows-vfixture"
        shutil.copytree(self.root, candidate)
        metadata = workspace / "build/release/metadata"
        metadata.mkdir()
        shutil.copyfile(self.cargo, metadata / "cargo-metadata.json")
        shutil.copyfile(self.dart, metadata / "dart-deps.json")
        summary = workspace / "failed-summary.json"
        summary.write_text('{"status":"INCOMPLETE","exit_code":3}')
        env = dict(os.environ, GITHUB_REF_NAME="vfixture", GITHUB_SHA="fixture-commit",
                   SCAN_SUMMARY=str(summary), PYTHONDONTWRITEBYTECODE="1")
        # Workflow blocks invoke python3; on Windows the store alias is not
        # executable, so bind python3 to the running interpreter first.
        pythonTools = self.base / "python3-tools"
        pythonTools.mkdir()
        pythonLink = pythonTools / "python3"
        pythonLink.symlink_to(sys.executable)
        env["PATH"] = str(pythonTools) + os.pathsep + env["PATH"]
        workflow = (repository / ".github/workflows/release.yml").read_text()

        def block(step):
            section = workflow.split("      - name: " + step + "\n", 1)[1]
            text = section.split("        run: |\n", 1)[1]
            lines = []
            for line in text.splitlines():
                if line and not line.startswith("          "):
                    break
                lines.append(line[10:])
            return "\n".join(lines)

        commands = block("生成证据、目录完整性及 ZIP 摘要校验")
        result = subprocess.run(["bash", "-c", commands], cwd=workspace, env=env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        checker.verify(candidate)
        checker.verify_zip(candidate.with_name(candidate.name + ".zip"))
        info = json.loads((candidate / "evidence/build-info.json").read_text())
        self.assertEqual(info["scan_report_sha256"], {summary.name: release.sha256(summary)})
        strict = subprocess.run(["bash", "-c", block("严格证据元数据门禁")], cwd=workspace,
                                env=env, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(strict.returncode, 0)
        self.assertIn("unknown metadata", (workspace / "build/reports/evidence-strict.txt").read_text())
        # pipefail must propagate real integrity failure despite successful tee.
        (candidate / "keel.exe").write_text("changed")
        failed = subprocess.run(["bash", "-c",
                                'set -euo pipefail; python3 -B scripts/verify_release_evidence.py '
                                '--root "build/release/keel-windows-vfixture" 2>&1 | '
                                'tee build/reports/tamper.txt'], cwd=workspace, env=env,
                                text=True, capture_output=True, timeout=30)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("checksum mismatch", (workspace / "build/reports/tamper.txt").read_text())
