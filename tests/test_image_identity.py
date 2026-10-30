"""Image identity regressions using real files and disposable Git repositories.

No image build, device access, mount or sudo is required.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/mo-62a-flash.sh'
FIELDS = ('MO_BOARD', 'MO_IMAGE_NAME', 'MO_IMAGE_VERSION', 'MO_BUILD_DATE',
          'MO_KERNEL', 'MO_ROOTFS_TARBALL', 'MO_SOURCE_COMMIT', 'MO_SOURCE_DIRTY')


class ImageIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mo62a-identity-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'sdk'
        self.script = self.repo / 'bin/mo-62a-flash.sh'
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.script)
        self.rootfs = self.base / 'rootfs'
        (self.rootfs / 'usr/lib/modules/6.12.35-test').mkdir(parents=True)
        # A stale, lexically newer modules tree must not determine MO_KERNEL.
        (self.rootfs / 'usr/lib/modules/99.0-stale').mkdir()
        self.kernel = self.base / 'kernel'
        (self.kernel / 'include/config').mkdir(parents=True)
        (self.kernel / 'include/config/kernel.release').write_text('6.12.35-test\n')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args],
                                       text=True, stderr=subprocess.DEVNULL).strip()

    def init_git(self):
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def run_shell(self, code, **env):
        return subprocess.run(['bash', '-c', 'source "$1";\n' + code,
                               'test', str(self.script)],
                              env={**os.environ, 'TEST_ROOTFS': str(self.rootfs),
                                   'TEST_KERNEL': str(self.kernel), **env},
                              capture_output=True, text=True, timeout=15)

    def identity(self):
        result = self.run_shell('load_source_identity; printf "%s|%s|%s" '
                                '"$IMAGE_VERSION" "$SOURCE_COMMIT" "$SOURCE_DIRTY"')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split('|')

    def test_unpacked_source_help_and_explicit_version_work(self):
        help_result = subprocess.run(['bash', str(self.script), '--help'], capture_output=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertEqual(self.identity(), ['', 'unknown', 'unknown'])
        archive = self.base / 'base.tar'
        archive.write_bytes(b'fixture')
        result = subprocess.run(['bash', str(self.script), '--image', '--rootfs', str(archive),
                                 '--version', 'V2.3.4', '--output-dir', str(self.base / 'out'),
                                 '--dry-run'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mo62a-trixie-xfce-V2.3.4.img', result.stdout)
        self.assertFalse((self.base / 'out').exists())

    def test_exact_clean_tag_not_highest_tag_in_repository(self):
        original = self.init_git()
        self.git('tag', 'V1.2.3')
        self.git('commit', '--allow-empty', '-qm', 'other revision')
        self.git('tag', 'V99.0.0')
        self.git('checkout', '-q', original)
        self.git('tag', 'V99.0.0-rc1')
        self.git('tag', 'V01.2.3')
        self.assertEqual(self.identity(), ['V1.2.3', original, '0'])

    def test_untagged_and_dirty_builds_have_no_default(self):
        self.init_git()
        self.git('tag', 'V1.2.3')
        self.git('commit', '--allow-empty', '-qm', 'development revision')
        sha = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.identity(), ['', sha, '0'])
        self.git('tag', 'V1.2.4')
        with self.script.open('a') as stream:
            stream.write('\n# local edit\n')
        self.assertEqual(self.identity(), ['', sha, '1'])
        self.git('checkout', '--', 'bin/mo-62a-flash.sh')
        (self.repo / 'untracked-source').write_text('local addition')
        self.assertEqual(self.identity(), ['', sha, '1'])

    def test_parent_repository_is_not_sdk_provenance(self):
        subprocess.run(['git', 'init', '-q', str(self.base)], check=True)
        self.assertEqual(self.identity(), ['', 'unknown', 'unknown'])

    def write_identity(self, archive='base rootfs.tar', prefix=''):
        return self.run_shell(prefix + '''
load_source_identity
ROOTFS_MNT="$TEST_ROOTFS"
ROOTFS_TARBALL="$TEST_ARCHIVE"
IMAGE_VERSION=v2.3.4
IMAGE_DATE=2026-10-30
NAME=stale-name
find_kernel_dir() { printf '%s' "$TEST_KERNEL"; }
write_release_file
''', TEST_ARCHIVE=archive)

    def read_identity(self):
        path = self.rootfs / 'etc/mo-62a-release'
        code = 'source "$1"; printf "%s\\0" ' + ' '.join('"$' + f + '"' for f in FIELDS)
        data = subprocess.check_output(['bash', '-c', code, 'test', str(path)])
        return dict(zip(FIELDS, data.decode().rstrip('\0').split('\0')))

    def test_real_file_uses_selected_version_built_kernel_and_source(self):
        sha = self.init_git()
        result = self.write_identity()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_identity(), dict(zip(FIELDS, (
            'Mo 62A', 'mo62a-trixie-xfce-V2.3.4', 'V2.3.4', '2026-10-30',
            '6.12.35-test', 'base rootfs.tar', sha, '0'))))
        info = (self.rootfs / 'etc/mo-62a-release').stat()
        self.assertEqual(info.st_mode & 0o777, 0o644)
        self.assertEqual(info.st_uid, os.geteuid())

    def test_metadata_quoting_round_trips_without_expansion(self):
        name = 'base "quoted" $USER `uname` \\ file.tar'
        result = self.write_identity(name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_identity()['MO_ROOTFS_TARBALL'], name)

    def test_bad_metadata_preserves_previous_file(self):
        (self.rootfs / 'etc').mkdir()
        target = self.rootfs / 'etc/mo-62a-release'
        target.write_text('previous identity\n')
        result = self.write_identity('bad\nname.tar')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'previous identity\n')
        self.assertEqual(list((self.rootfs / 'etc').glob('.mo-62a-release.*')), [])

    def test_missing_built_kernel_modules_refuses_identity(self):
        (self.rootfs / 'usr/lib/modules/6.12.35-test').rmdir()
        result = self.write_identity()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Built kernel modules are missing', result.stderr)
        self.assertFalse((self.rootfs / 'etc/mo-62a-release').exists())

    def test_sd_full_and_rootfs_prompts_update_name_before_confirmation(self):
        for mode in ['full', 'rootfs']:
            with self.subTest(mode=mode):
                result = self.run_shell('''
pick_device() { echo /dev/fixture; }
get_disk_size() { echo fixture; }
pick_mode_interactive() { SD_MODE="$TEST_MODE"; }
prompt_with_default() {
  case "$1" in Version*) echo v2.3.4 ;; *) echo 2026-10-30 ;; esac
}
confirm_or_die() { printf 'IDENTITY:%s|%s' "$NAME" "$IMAGE_VERSION"; exit 0; }
run_sd_flow
''', TEST_MODE=mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('IDENTITY:mo62a-trixie-xfce-V2.3.4|V2.3.4', result.stdout)


if __name__ == '__main__':
    unittest.main()
