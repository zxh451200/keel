import copy
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import advisory_provenance as provenance


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "rust").mkdir()
        self.reports = self.root / "reports"
        self.reports.mkdir()
        self.text = ('[advisories]\ndb-urls = ["' + provenance.RUSTSEC_URL + '"]\n'
                     'db-path = "~/.cargo/advisory-db"\nignore = ["fixture-policy"]\n'
                     '[licenses]\nallow = ["MIT"]\n')
        (self.root / "rust/deny.toml").write_text(self.text)
        self.values = {"origin": provenance.RUSTSEC_URL, "HEAD": "a" * 40,
                       "HEAD^{tree}": "b" * 40, "--untracked-files=all": ""}
        self.commands = []

    def capture(self, command, cwd):
        self.commands.append(command)
        if command[:2] == ["cargo", "deny"]:
            (self.reports / "rustsec-cache/actual-url-hash/.git").mkdir(parents=True)
            return 0, "fixture online fetch completed"
        return 0, self.values[command[-1]]

    def snapshot(self):
        snapshot = provenance.prepare(self.root, self.reports, self.capture)
        return provenance.finish(snapshot, self.capture)

    def test_actual_database_path_revision_and_policy(self):
        snapshot = self.snapshot()
        self.assertEqual(provenance.validate(snapshot), "a" * 40)
        self.assertEqual(snapshot["before"]["path"], str(self.reports / "rustsec-cache/actual-url-hash"))
        config = Path(snapshot["config"]).read_text()
        self.assertIn('ignore = ["fixture-policy"]', config)
        self.assertIn('allow = ["MIT"]', config)
        self.assertEqual((self.root / "rust/deny.toml").read_text(), self.text)
        self.assertEqual(self.commands[0], ["cargo", "deny", "--config", snapshot["config"], "fetch", "db"])

    def test_failed_online_fetch_blocks_even_if_repository_exists(self):
        def offline(command, cwd):
            if command[0] == "cargo":
                return 2, "failed to connect"
            return self.capture(command, cwd)
        snapshot = provenance.prepare(self.root, self.reports, offline)
        self.assertEqual(snapshot["status"], "unknown")
        with self.assertRaises(ValueError):
            provenance.validate(snapshot)

    def test_dirty_wrong_remote_and_failed_git_observations_block(self):
        for key, value in (("origin", "https://attacker.invalid/advisory-db"),
                           ("HEAD", "not-a-revision"), ("--untracked-files=all", " M advisory.toml")):
            with self.subTest(key=key):
                values = dict(self.values, **{key: value})
                observed = provenance.observe(self.root, lambda cmd, cwd: (0, values[cmd[-1]]))
                self.assertEqual(observed["status"], "unknown")
        observed = provenance.observe(self.root, lambda cmd, cwd: (1, ""))
        self.assertEqual(observed["status"], "unknown")

    def test_revision_change_during_scan_blocks(self):
        snapshot = provenance.prepare(self.root, self.reports, self.capture)
        self.values["HEAD"] = "c" * 40
        snapshot = provenance.finish(snapshot, self.capture)
        self.assertEqual(snapshot["status"], "unknown")
        with self.assertRaisesRegex(ValueError, "unverified"):
            provenance.validate(snapshot)

    def test_claimed_revision_without_observations_is_rejected(self):
        snapshot = self.snapshot()
        snapshot["before"]["observations"] = {}
        snapshot["after"] = copy.deepcopy(snapshot["before"])
        with self.assertRaisesRegex(ValueError, "observation"):
            provenance.validate(snapshot)

    def test_unknown_config_and_ambiguous_database_block(self):
        (self.root / "rust/deny.toml").write_text(self.text.replace(provenance.RUSTSEC_URL, "https://example.invalid"))
        self.assertEqual(provenance.prepare(self.root, self.reports, self.capture)["status"], "unknown")
        self.assertFalse(self.commands)
        (self.root / "rust/deny.toml").write_text(self.text)
        (self.reports / "rustsec-cache/another/.git").mkdir(parents=True)
        self.assertEqual(provenance.prepare(self.root, self.reports, self.capture)["status"], "unknown")
