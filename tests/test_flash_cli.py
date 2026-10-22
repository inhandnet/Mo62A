"""Non-destructive CLI and mocked-flow tests; no sudo, mounts or image builds.

Run: python3 -m unittest discover -s tests -p 'test_flash_cli.py' -v
"""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "bin/mo-62a-flash.sh"


class FlashCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mo62a-cli-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.rootfs = self.base / "base system.tar"
        self.rootfs.write_bytes(b"test fixture, not a real archive\n")
        self.output = self.base / "output with spaces"

    def args(self, **changes):
        values = {
            "--rootfs": str(self.rootfs), "--version": "V1.1.0",
            "--output-dir": str(self.output), "--date": "2026-10-15",
        }
        values.update(changes)
        return ["--image"] + [part for key, value in values.items()
                              if value is not None for part in (key, value)]

    def run_cli(self, args, code=None, env=None):
        command = (["bash", str(SCRIPT)] if code is None else
                   ["bash", "-c", 'source "$1"; shift;\n' + code, "test", str(SCRIPT)])
        return subprocess.run(command + args, input="", text=True,
                              capture_output=True, timeout=10,
                              env={**os.environ, **(env or {})})

    def test_help_and_source_do_not_run_main(self):
        self.assertEqual(self.run_cli(["--help"]).returncode, 0)
        result = self.run_cli([], code='echo "loaded"')
        self.assertEqual(result.stdout.strip(), "loaded")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dry_run_defaults_without_creating_output(self):
        result = self.run_cli(self.args() + ["--dry-run"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for value in ["size (GiB):  12", "compression: xz", "V1.1.0.img.xz", "V1.1.0.sha256"]:
            self.assertIn(value, result.stdout)
        self.assertFalse(self.output.exists())

    def test_lowercase_tag_and_overrides(self):
        result = self.run_cli(self.args(**{"--version": "v2.3.4", "--image-size-gib": "16",
                                          "--compression": "zip"}) + ["--dry-run"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("V2.3.4.img.zip", result.stdout)
        self.assertIn("size (GiB):  16", result.stdout)

    def test_none_compression(self):
        result = self.run_cli(self.args(**{"--compression": "none"}) + ["--dry-run"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("compressed:", result.stdout)

    def test_required_options(self):
        for option in ["--rootfs", "--version", "--output-dir"]:
            with self.subTest(option=option):
                result = self.run_cli(self.args(**{option: None}) + ["--dry-run"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(option + " is required", result.stderr)

    def test_invalid_inputs_rejected_before_writes(self):
        cases = {
            "--version": ["../escape", "1.1.0", "V01.1.0", "V1.1.0-rc.1", "V1.1.0/../../escape"],
            "--image-size-gib": ["0", "4", "2048", "9999999999999999999999", "012", "1+12"],
            "--date": ["2026-02-30", "tomorrow", "2026-1-1"],
            "--compression": ["gzip", "xz;false"],
            "--rootfs": [str(self.base / "missing.tar"), str(self.base)],
            "--output-dir": ["/dev", "/proc/image", "/sys/image", str(self.rootfs)],
        }
        for option, values in cases.items():
            for value in values:
                with self.subTest(option=option, value=value):
                    result = self.run_cli(self.args(**{option: value}) + ["--dry-run"])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("ERROR:", result.stderr)
                    self.assertFalse(self.output.exists())

    def test_unsupported_duplicate_and_missing_value_options(self):
        for extra in [["--device", "/dev/sda"], ["--force"], ["--version"],
                      ["--rootfs", "other.tar"], ["--compression", "--dry-run"], [""]]:
            with self.subTest(extra=extra):
                result = self.run_cli(self.args() + extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
        result = self.run_cli(self.args()[1:] + ["--dry-run"])
        self.assertIn("require --image", result.stderr)

    def test_lfs_pointer_and_empty_archive(self):
        for data in [b"", b"version https://git-lfs.github.com/spec/v1\noid sha256:000\nsize 123\n"]:
            self.rootfs.write_bytes(data)
            result = self.run_cli(self.args() + ["--dry-run"])
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.output.exists())

    def test_existing_outputs_including_dangling_symlinks_are_preserved(self):
        self.output.mkdir()
        names = ["mo62a-trixie-xfce-V1.1.0" + ext for ext in
                 [".img", ".img.xz", ".img.zip", ".sha256"]] + ["mo62a-factory-V1.1.0.deb"]
        for name in names:
            with self.subTest(name=name):
                target = self.output / name
                target.write_text("keep me")
                result = self.run_cli(self.args() + ["--dry-run"])
                self.assertIn("Refusing to overwrite", result.stderr)
                self.assertEqual(target.read_text(), "keep me")
                target.unlink()
        target.symlink_to(self.base / "missing")
        result = self.run_cli(self.args() + ["--dry-run"])
        self.assertIn("Refusing to overwrite", result.stderr)
        self.assertTrue(target.is_symlink())

    def test_output_symlink_to_devices_is_rejected(self):
        self.output.symlink_to("/dev", target_is_directory=True)
        result = self.run_cli(self.args() + ["--dry-run"])
        self.assertIn("Unsafe output directory", result.stderr)

    def mock_flow(self, interactive=False, fail_step=""):
        # All privileged, destructive and build operations are replaced by functions.
        # Only mkdir/rmdir for this test's temporary directories remain real.
        code = r'''
BUILT_IMAGES_DIR="$TEST_BASE"
EXTLINUX_SRC_DIR="$TEST_BASE"
require_root() { :; }
pick_flash_mode() { echo image; }
pick_rootfs_tarball_interactive() { echo "$TEST_ROOTFS"; }
prompt_with_default() {
  if [[ "$1" == 'Output directory' ]]; then echo "$TEST_OUT"; else echo "$2"; fi
}
confirm_or_die() { echo STEP:confirm; }
mock_step() {
  echo "STEP:$1"
  if [[ "$1" == "${FAIL_STEP:-}" ]]; then return 17; fi
}
for step in build_factory_deb create_sparse_image partition_image_mbr copy_boot_files \
  img_extract_rootfs_tarball install_kernel_modules_into_rootfs \
  install_external_apps_into_rootfs install_external_drivers_into_rootfs \
  install_rootfs_overlay write_release_file compress_outputs write_checksums; do
  eval "$step() { mock_step $step; }"
done
attach_loop() { LOOPDEV=/dev/mock-loop; }
format_and_mount_loop_parts() {
  BOOT_MNT="$TEST_BASE/mock-boot"
  ROOTFS_MNT="$TEST_BASE/mock-rootfs"
  mkdir "$BOOT_MNT" "$ROOTFS_MNT"
}
sync() { :; }
umount() { :; }
losetup() { :; }
mountpoint() { return 1; }
main "$@"
'''
        return self.run_cli([] if interactive else self.args(), code=code, env={
            "TEST_BASE": str(self.base), "TEST_ROOTFS": str(self.rootfs),
            "TEST_OUT": str(self.output), "FAIL_STEP": fail_step,
        })

    def test_batch_uses_shared_steps_without_prompt(self):
        result = self.mock_flow()
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = [line for line in result.stdout.splitlines() if line.startswith("STEP:")]
        self.assertEqual(steps, ["STEP:" + step for step in [
            "build_factory_deb", "create_sparse_image", "partition_image_mbr", "copy_boot_files",
            "img_extract_rootfs_tarball", "install_kernel_modules_into_rootfs",
            "install_external_apps_into_rootfs", "install_external_drivers_into_rootfs",
            "install_rootfs_overlay", "write_release_file", "compress_outputs", "write_checksums",
        ]])
        self.assertEqual(list(self.output.iterdir()), [])  # lock released

    def test_failed_install_stops_before_compression_and_releases_lock(self):
        result = self.mock_flow(fail_step="install_external_drivers_into_rootfs")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn("STEP:compress_outputs", result.stdout)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_existing_lock_is_preserved(self):
        self.output.mkdir()
        lock = self.output / ".mo62a-trixie-xfce-V1.1.0.lock"
        lock.mkdir()
        result = self.mock_flow()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output is locked", result.stderr)
        self.assertTrue(lock.is_dir())
        self.assertNotIn("STEP:build_factory_deb", result.stdout)

    def test_interactive_image_still_confirms_before_output(self):
        result = self.mock_flow(interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index("STEP:confirm"), result.stdout.index("STEP:build_factory_deb"))

    def test_interactive_sd_routing_unchanged(self):
        result = self.run_cli([], code='''
require_root() { :; }
cleanup() { :; }
pick_flash_mode() { echo sd; }
run_sd_flow() { echo SD_ROUTE_ONLY; }
main
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SD_ROUTE_ONLY", result.stdout)

    def test_sd_and_image_installation_order_matches(self):
        source = SCRIPT.read_text()
        expected = ["install_kernel_modules_into_rootfs", "install_external_apps_into_rootfs",
                    "install_external_drivers_into_rootfs", "install_rootfs_overlay"]
        for name in ["sd_extract_rootfs", "run_image_flow"]:
            body = re.search(r"^" + name + r"\(\) \{(.*?)^\}", source, re.M | re.S)
            self.assertIsNotNone(body)
            self.assertEqual(re.findall(r"^  (install_[a-z_]+)$", body[1], re.M), expected)


if __name__ == "__main__":
    unittest.main()
