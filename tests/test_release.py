import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from commit_policy import check_title, load_yaml, parse_message
import release
from validate_release_event import main as validate_event


def message(kind="fix", en="Fix the image assembly.", zh="修复镜像制作流程。"):
    return f'{kind}(image): improve image assembly\n\nMessage:\n  en: {en}\n  zh: {zh}\n'


class CommitPolicyTests(unittest.TestCase):
    def test_release_checkout_pins_commit_and_preserves_tags(self):
        workflow = yaml.safe_load((release.ROOT / '.github/workflows/release.yml').read_text())
        for name in ('validate', 'build', 'publish'):
            checkout = next(s for s in workflow['jobs'][name]['steps']
                            if s.get('uses', '').startswith('actions/checkout@'))
            self.assertEqual(checkout['with']['ref'], '${{ github.sha }}')
            if name != 'publish':
                self.assertEqual(checkout['with']['fetch-depth'], 0)

    def test_valid_bilingual_and_breaking(self):
        self.assertEqual(parse_message(message())["messages"]["zh"], "修复镜像制作流程。")
        self.assertTrue(parse_message(message().replace("): ", ")!: "))["breaking"])

    def test_missing_or_wrong_language(self):
        for value in ["fix: change", message(en="只有中文"), message(zh="English only"),
                      message().replace("  zh:", "  cn:"), message()+"Other: no\n"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError): parse_message(value)

    def test_duplicate_yaml_keys(self):
        with self.assertRaises(ValueError): load_yaml("Message: a\nMessage: b\n")

    def test_subject_and_private_network_rules(self):
        for title in ["update", "fix: Uppercase", "fix: trailing.", "fix: 中文", "misc: something"]:
            with self.assertRaises(ValueError): check_title(title)
        with self.assertRaises(ValueError): parse_message(message(en="Connect to 192.168.1.2."))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mo62a-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.previous_cwd = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous_cwd)
        self.git("init", "-b", "master")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "test@example.com")
        (self.root / "release-notes").mkdir()
        for lang in ("en", "zh"):
            (self.root / "release-notes" / f"V1.1.0.{lang}.md").write_text("### Baseline\n\nInitial release.\n")
        self.git("add", "release-notes")
        self.git("commit", "-m", "legacy commit without bilingual fields")
        self.git("tag", "-a", "V1.1.0", "-m", "baseline")

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, text):
        self.git("commit", "--allow-empty", "-m", text)

    def test_bootstrap_uses_seed_not_legacy_commits(self):
        rows = release.history("V1.1.0", "HEAD")
        self.assertEqual(len(rows), 1)
        self.assertIn("Initial release", rows[0]["notes"]["en"])

    def test_tag_gate_accepts_annotation_and_rejects_flattened_checkout(self):
        self.git('update-ref', 'refs/remotes/origin/master', 'HEAD')
        config = release.settings()
        env = dict(VERSION='V1.1.0', GITHUB_REPOSITORY=config['repository'],
                   ACTOR_ID=str(config['publisher_id']), TRIGGERING_ACTOR=config['publisher_login'],
                   EVENT='push', GITHUB_REF='refs/tags/V1.1.0')
        with patch.dict(os.environ, env):
            validate_event()
            self.git('update-ref', 'refs/tags/V1.1.0', 'HEAD')
            with self.assertRaisesRegex(ValueError, 'annotated tag'):
                validate_event()

    def test_cumulative_history_contains_all_commits_once(self):
        self.commit(message())
        self.commit(message("docs", "Document installation.", "完善安装文档。"))
        self.git("tag", "-a", "V1.1.1", "-m", "next")
        self.commit(message("feat", "Add a new feature.", "新增功能。"))
        output = self.root / "dist"
        rows = release.generate("V1.2.0", "HEAD", output)
        self.assertEqual([r["version"] for r in rows], ["V1.2.0", "V1.1.1", "V1.1.0"])
        en = (output / "CHANGELOG.en.md").read_text()
        self.assertEqual(en.count("Fix the image assembly"), 1)
        self.assertEqual(en.count("Document installation"), 1)
        self.assertIn("新增功能", (output / "CHANGELOG.zh.md").read_text())
        body = (output / "release-body.md").read_text()
        self.assertIn("<summary>中文</summary>", body)
        self.assertNotIn("Document installation", body)

    def test_invalid_commit_and_duplicate_release_are_rejected(self):
        with self.assertRaises(ValueError): release.history("V1.1.1", "HEAD")
        self.commit("fix: missing translation")
        with self.assertRaises(ValueError): release.history("V1.1.1", "HEAD")

    def test_tag_source_mismatch_is_rejected(self):
        self.commit(message())
        with self.assertRaises(ValueError): release.history("V1.1.0", "HEAD")

    def test_manifest_asset_names_checksums_and_size_limit(self):
        output = self.root / "dist"
        output.mkdir()
        image = output / "mo62a-trixie-xfce-V1.1.0.img.xz"
        image.write_bytes(b"small test fixture")
        release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test")
        manifest = json.loads((output / "release.json").read_text())
        self.assertEqual(manifest["image"]["sha256"], release.checksum(image))
        self.assertFalse(manifest["validation"]["hardwareBootTest"])
        self.assertNotIn("hardwareBootTestEvidence", manifest["validation"])
        self.assertEqual(len((output / "SHA256SUMS").read_text().splitlines()), 4)
        with patch.object(release, "settings", return_value={**release.settings(), "asset_limit_bytes": 2}):
            with self.assertRaises(ValueError):
                release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test")

    def test_boot_test_evidence_sets_hardware_boot_result(self):
        output = self.root / "dist"
        output.mkdir()
        image = output / "mo62a-trixie-xfce-V1.1.0.img.xz"
        image.write_bytes(b"small test fixture")
        commit = release.git("rev-parse", "HEAD")
        record = {"version": "V1.1.0", "commit": commit, "kernel": "6.12-test", "board": "Mo62A rev V1.1",
                  "image_name": "mo62a-trixie-xfce-V1.1.0.img.xz", "date": "2026-10-24",
                  "result": "passed", "tester": "board lab", "method": "flashed to microSD, booted to desktop, SSH login"}
        folder = self.root / "validation" / "boot-tests"
        folder.mkdir(parents=True)
        file = folder / "V1.1.0.json"
        with patch.object(release, "BOOT_TESTS", folder):
            file.write_text(json.dumps(record))
            release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test")
            manifest = json.loads((output / "release.json").read_text())
            self.assertTrue(manifest["validation"]["hardwareBootTest"])
            self.assertEqual(manifest["validation"]["hardwareBootTestEvidence"]["tester"], "board lab")
            file.write_text(json.dumps({**record, "result": "failed"}))
            release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test")
            self.assertFalse(json.loads((output / "release.json").read_text())["validation"]["hardwareBootTest"])
            file.write_text(json.dumps({**record, "commit": "0" * 40}))
            with self.assertRaises(ValueError):
                release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test")


if __name__ == "__main__":
    unittest.main()
