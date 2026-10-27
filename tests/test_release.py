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
import sbom
from validate_release_event import main as validate_event


DPKG_STATUS = """Package: zlib1g
Status: install ok installed
Architecture: arm64
Maintainer: Mark Brown <broonie@debian.org>
Version: 1:1.3.dfsg+really1.3.1-1+b1
Source: zlib
Description: compression library
 runtime

Package: removed-tool
Status: deinstall ok config-files
Architecture: arm64
Version: 1.0

Package: bash
Status: install ok installed
Architecture: arm64
Maintainer: Matthias Klose <doko@debian.org>
Version: 5.2.37-2
Homepage: http://tiswww.case.edu/php/chet/bash/bashtop.html
"""


class SbomTests(unittest.TestCase):
    def test_lists_installed_packages_and_kernel_deterministically(self):
        doc = sbom.build("V1.1.0", "mo62a-trixie-xfce-V1.1.0.img.xz", "6.12-test", "2026-10-26", DPKG_STATUS)
        names = [p["name"] for p in doc["packages"]]
        self.assertEqual(names, ["mo62a-trixie-xfce-V1.1.0.img.xz", "linux", "bash", "zlib1g"])
        self.assertEqual(doc["spdxVersion"], "SPDX-2.3")
        self.assertEqual(doc["creationInfo"]["created"], "2026-10-26T00:00:00Z")
        zlib = doc["packages"][3]
        self.assertEqual(zlib["externalRefs"][0]["referenceLocator"],
                         "pkg:deb/debian/zlib1g@1:1.3.dfsg+really1.3.1-1+b1?arch=arm64")
        self.assertEqual(zlib["supplier"], "Organization: Debian")
        self.assertEqual(len(doc["relationships"]), 4)
        again = sbom.build("V1.1.0", "mo62a-trixie-xfce-V1.1.0.img.xz", "6.12-test", "2026-10-26", DPKG_STATUS)
        self.assertEqual(doc, again)

    def test_rejects_empty_or_invalid_input(self):
        for args in [("V1.1", "x", "6.12", "2026-10-26", DPKG_STATUS),
                     ("V1.1.0", "x", "6.12", "26-10-2026", DPKG_STATUS),
                     ("V1.1.0", "x", "6.12", "2026-10-26", "Package: a\nStatus: deinstall ok config-files\n")]:
            with self.subTest(args=args):
                with self.assertRaises(ValueError): sbom.build(*args)


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

    def test_release_validation_checks_out_what_the_tests_read(self):
        def paths(workflow, job):
            data = yaml.safe_load((release.ROOT / '.github/workflows' / workflow).read_text())
            step = next(s for s in data['jobs'][job]['steps'] if s.get('uses', '').startswith('actions/checkout@'))
            return set(step['with']['sparse-checkout'].split())
        self.assertLessEqual(paths('ci.yml', 'validate-release'), paths('release.yml', 'validate'))

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

    def write_sbom(self, output):
        file = output / "mo62a-trixie-xfce-V1.1.0.spdx.json"
        file.write_text(json.dumps(sbom.build("V1.1.0", "mo62a-trixie-xfce-V1.1.0.img.xz", "6.12-test",
                                              "2026-10-26", DPKG_STATUS)))
        return file

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
        self.sbom = self.write_sbom(output)
        release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test", self.sbom)
        manifest = json.loads((output / "release.json").read_text())
        self.assertEqual(manifest["image"]["sha256"], release.checksum(image))
        self.assertFalse(manifest["validation"]["hardwareBootTest"])
        self.assertNotIn("hardwareBootTestEvidence", manifest["validation"])
        self.assertEqual(len((output / "SHA256SUMS").read_text().splitlines()), 5)
        self.assertEqual(manifest["sbom"]["name"], "mo62a-trixie-xfce-V1.1.0.spdx.json")
        self.assertEqual(manifest["sbom"]["packages"], 4)
        with self.assertRaises(ValueError):
            release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test")
        with patch.object(release, "settings", return_value={**release.settings(), "asset_limit_bytes": 2}):
            with self.assertRaises(ValueError):
                release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test", self.sbom)

    def test_tagged_build_is_not_hardware_validated(self):
        output, manifest = self.build_draft()
        self.assertFalse(manifest["validation"]["hardwareBootTest"])
        self.assertNotIn("hardware", manifest["validation"])

    def build_draft(self):
        output = self.root / "dist"
        output.mkdir()
        image = output / "mo62a-trixie-xfce-V1.1.0.img.xz"
        image.write_bytes(b"small test fixture")
        self.sbom = self.write_sbom(output)
        release.generate("V1.1.0", "HEAD", output, image, 12*1024**3, "6.12-test", self.sbom)
        return output, json.loads((output / "release.json").read_text())

    def record(self, manifest, **changes):
        record = {"version": "V1.1.0", "commit": manifest["source"]["commit"],
                  "image": {"name": manifest["image"]["name"], "sha256": manifest["image"]["sha256"]},
                  "kernel": "6.12-test", "board": "Mo62A PCB V1.1, 4 GB", "date": "2026-10-27",
                  "tester": "board lab", "result": "passed",
                  "companions": {"mo-tools": "V1.0.0", "mo-models": "V1.0.0", "mo-examples": "V1.0.0"},
                  "tests": [{"id": "boot", "item": "Boots to the desktop", "result": "passed"},
                            {"id": "wifi", "item": "Wi-Fi connect", "result": "skipped", "evidence": "no access point"}]}
        record.update(changes)
        return record

    def test_finalize_adds_validation_to_the_draft(self):
        output, manifest = self.build_draft()
        file = self.root / "V1.1.0.json"
        file.write_text(json.dumps(self.record(manifest)))
        image_line = next(l for l in (output / "SHA256SUMS").read_text().splitlines() if l.endswith(".img.xz"))
        result = release.finalize("V1.1.0", output, file)
        self.assertTrue(result["validation"]["hardwareBootTest"])
        self.assertEqual(result["validation"]["hardware"]["tests"], {"passed": 1, "failed": 0, "skipped": 1})
        self.assertEqual(result["validation"]["hardware"]["companions"]["mo-models"], "V1.0.0")
        sums = (output / "SHA256SUMS").read_text().splitlines()
        self.assertIn(image_line, sums)
        self.assertIn(f'{release.checksum(output / "validation.json")}  validation.json', sums)
        self.assertIn(f'{release.checksum(output / "release.json")}  release.json', sums)

    def test_finalize_rejects_records_for_another_build(self):
        _, manifest = self.build_draft()
        bad = [{"commit": "0" * 40}, {"image": {"name": manifest["image"]["name"], "sha256": "0" * 64}},
               {"kernel": "6.12-other"}, {"companions": {"mo-tools": "V1.0.0"}},
               {"result": "passed", "tests": [{"id": "boot", "item": "Boot", "result": "failed"}]},
               {"result": "failed"}]
        for change in bad:
            with self.subTest(change=change):
                output = self.root / "dist"
                file = self.root / "V1.1.0.json"
                file.write_text(json.dumps(self.record(manifest, **change)))
                with self.assertRaises(ValueError):
                    release.finalize("V1.1.0", output, file)

if __name__ == "__main__":
    unittest.main()
