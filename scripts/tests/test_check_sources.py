import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "check_sources", Path(__file__).resolve().parents[1] / "check_sources.py"
)
source_checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_checks)


class GeneratedFrbTests(unittest.TestCase):
    def check_fixture(self, source, generated):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            api = root / "rust/src/api"
            api.mkdir(parents=True)
            dart = root / "lib/src/rust/api"
            dart.mkdir(parents=True)
            (api / "mod.rs").write_text("pub mod sample;\n", encoding="utf-8")
            if source is not None:
                (api / "sample.rs").write_text(source, encoding="utf-8")
            if generated is not None:
                (dart / "sample.dart").write_text(generated, encoding="utf-8")
            errors, pending = [], []
            with patch.object(source_checks, "ROOT", root):
                source_checks.check_generated_frb(errors, pending)
            return errors, pending

    def test_missing_module_is_pending_even_without_dart_import(self):
        errors, pending = self.check_fixture("pub fn load_history() {}", None)
        self.assertEqual(errors, [])
        self.assertEqual(pending, [
            "missing generated FRB module: lib/src/rust/api/sample.dart",
        ])

    def test_existing_module_cannot_hide_new_async_function(self):
        source = "pub fn old_value() {}\npub async fn load_history(\n) {}\n"
        generated = "int oldValue() => 1;\n// Future<void> loadHistory() => stub;\n"
        errors, pending = self.check_fixture(source, generated)
        self.assertEqual(errors, [])
        self.assertEqual(pending, ["missing generated FRB function: sample.loadHistory"])
        self.assertEqual(self.check_fixture(
            source, generated + "Future<void> loadHistory(\n) => bridge();\n",
        ), ([], []))

    def test_init_ignore_and_private_functions_have_no_wrapper(self):
        source = (
            "#[flutter_rust_bridge::frb(init)]\npub fn init_app() {}\n"
            "#[flutter_rust_bridge::frb(ignore)]\npub fn internal_only() {}\n"
            "pub(crate) fn helper() {}\nfn private() {}\n"
            "#[flutter_rust_bridge::frb(sync)]\npub fn ping_async() {}\n"
        )
        self.assertEqual(self.check_fixture(
            source, "int pingAsync() => bridge();\n",
        ), ([], []))

    def test_missing_rust_module_is_error(self):
        errors, pending = self.check_fixture(None, "")
        self.assertEqual(errors, ["missing Rust API source: rust/src/api/sample.rs"])
        self.assertEqual(pending, [])


class LocalizationMetadataTests(unittest.TestCase):
    def check_resources(self, en, zh):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            l10n = root / "lib/l10n"
            l10n.mkdir(parents=True)
            for locale, value in (("en", en), ("zh", zh)):
                (l10n / ("app_" + locale + ".arb")).write_text(
                    json.dumps(value), encoding="utf-8",
                )
            errors = []
            with patch.object(source_checks, "ROOT", root):
                source_checks.check_l10n(errors)
            return errors

    def test_optional_translation_metadata_and_matching_metadata(self):
        en = {"title": "{value}", "@title": {"placeholders": {"value": {}}}}
        self.assertEqual(self.check_resources(en, {"title": "{value}"}), [])
        self.assertEqual(self.check_resources(en, en), [])

    def test_explicit_translation_placeholder_mismatch_is_rejected(self):
        en = {"title": "{value}", "@title": {"placeholders": {"value": {}}}}
        zh = {"title": "{value}", "@title": {"placeholders": {"other": {}}}}
        self.assertIn("l10n placeholder metadata differs: zh.title",
                      self.check_resources(en, zh))

    def test_malformed_metadata_reports_errors_instead_of_crashing(self):
        en = {"title": "{value}", "@title": {"placeholders": {"value": {}}}}
        for bad in (None, [], "invalid"):
            with self.subTest(metadata=bad):
                self.assertTrue(self.check_resources(
                    en, {"title": "{value}", "@title": bad},
                ))
        for bad in ([], None, {"value": "invalid"}):
            with self.subTest(placeholders=bad):
                self.assertTrue(self.check_resources(
                    en, {"title": "{value}", "@title": {"placeholders": bad}},
                ))

    def test_non_object_resource_is_rejected(self):
        self.assertIn("l10n resource must be an object: zh",
                      self.check_resources({"title": "Title"}, []))


class GeneratedResourcesTests(unittest.TestCase):
    def test_existing_files_do_not_hide_new_arb_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            l10n = root / "lib" / "l10n"
            l10n.mkdir(parents=True)
            (l10n / "app_en.arb").write_text(
                json.dumps({"@@locale": "en", "title": "Title", "newKey": "New"}),
                encoding="utf-8",
            )
            for name in ("app_localizations", "app_localizations_en",
                         "app_localizations_zh"):
                (l10n / (name + ".dart")).write_text(
                    "String get title => 'Title';", encoding="utf-8"
                )
            with patch.object(source_checks, "ROOT", root):
                pending = []
                source_checks.check_generated_l10n(pending)
                self.assertEqual(len(pending), 3)
                self.assertTrue(all("newKey" in item for item in pending))
                for target in l10n.glob("*.dart"):
                    target.write_text(
                        "String get title => 'Title';\n"
                        "String newKey(String value) { return value; }",
                        encoding="utf-8",
                    )
                pending = []
                source_checks.check_generated_l10n(pending)
                self.assertEqual(pending, [])

    def test_absent_outputs_remain_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            l10n = root / "lib" / "l10n"
            l10n.mkdir(parents=True)
            (l10n / "app_en.arb").write_text('{"title":"Title"}', encoding="utf-8")
            with patch.object(source_checks, "ROOT", root):
                pending = []
                source_checks.check_generated_l10n(pending)
                self.assertEqual(len(pending), 3)
                self.assertTrue(all("missing generated file" in item for item in pending))
