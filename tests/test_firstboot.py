"""First-boot regressions; all writes stay in temporary test fixtures."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / 'board-support/rootfs-overlay'
CONFIG = OVERLAY / 'usr/local/sbin/mo-62a-auto-config.sh'
DISCOVERY = OVERLAY / 'usr/local/bin/mo-discover'


class HostnameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mo62a-hostname-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        (self.base / 'bin').mkdir()
        (self.base / 'hostname').write_text('old-name\n')
        (self.base / 'runtime').write_text('old-name\n')
        (self.base / 'hosts').write_text('127.0.0.1 localhost\n127.0.1.1 old-name\n::1 localhost\n')
        scripts = {
            'hostnamectl': '''#!/bin/bash
printf 'hostnamectl\\n' >> "$TEST_STATE/calls"
[ "$(cat "$TEST_STATE/hostname")" = "$2" ] || exit 88
[ "$HOSTNAMED_FAIL" = 0 ] || exit 1
printf '%s\\n' "$2" > "$TEST_STATE/runtime"
''',
            'hostname': '''#!/bin/bash
printf 'hostname\\n' >> "$TEST_STATE/calls"
[ "$RUNTIME_FAIL" = 0 ] || exit 1
printf '%s\\n' "$1" > "$TEST_STATE/runtime"
''',
        }
        for name, content in scripts.items():
            p = self.base / 'bin' / name
            p.write_text(content)
            p.chmod(0o755)

    def apply(self, hostnamed_fail=False, runtime_fail=False, name='board-test'):
        return subprocess.run(['bash', '-c', '''
source "$1"
HOSTNAME_FILE="$2/hostname"
HOSTS_FILE="$2/hosts"
CFG[hostname]="$3"
apply_hostname
''', 'test', str(CONFIG), str(self.base), name], text=True, capture_output=True, timeout=5,
            env={**os.environ, 'PATH': str(self.base / 'bin') + ':' + os.environ['PATH'],
                 'TEST_STATE': str(self.base), 'HOSTNAMED_FAIL': str(int(hostnamed_fail)),
                 'RUNTIME_FAIL': str(int(runtime_fail))})

    def test_hostname_is_persisted_before_hostnamed_and_applied(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'runtime').read_text(), 'board-test\n')
        self.assertEqual((self.base / 'calls').read_text(), 'hostnamectl\n')
        self.assertEqual((self.base / 'hosts').read_text(),
                         '127.0.0.1 localhost\n::1 localhost\n127.0.1.1\tboard-test\n')

    def test_hostnamed_failure_still_sets_kernel_hostname(self):
        result = self.apply(hostnamed_fail=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('WARNING', result.stdout)
        self.assertEqual((self.base / 'runtime').read_text(), 'board-test\n')
        self.assertEqual((self.base / 'calls').read_text(), 'hostnamectl\nhostname\n')

    def test_failed_runtime_update_is_reported(self):
        result = self.apply(hostnamed_fail=True, runtime_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ERROR: could not set runtime hostname', result.stdout)
        self.assertEqual((self.base / 'runtime').read_text(), 'old-name\n')

    def test_failed_persistence_does_not_change_runtime(self):
        (self.base / 'hostname').unlink()
        (self.base / 'hostname').mkdir()
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'calls').exists())

    def test_empty_hostname_leaves_system_unchanged(self):
        result = self.apply(name='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / 'calls').exists())
        self.assertEqual((self.base / 'hostname').read_text(), 'old-name\n')


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        loader = importlib.machinery.SourceFileLoader('mo_discover_test', str(DISCOVERY))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.module = importlib.util.module_from_spec(spec)
        loader.exec_module(self.module)

    def test_reply_address_uses_requesters_route_without_internet(self):
        sock = MagicMock()
        sock.getsockname.return_value = ('169.254.10.20', 40000)
        factory = MagicMock()
        factory.return_value.__enter__.return_value = sock
        with patch.object(self.module.socket, 'socket', factory):
            self.assertEqual(self.module._primary_ip('169.254.10.30'), '169.254.10.20')
        sock.connect.assert_called_once_with(('169.254.10.30', 47622))
        factory.return_value.__exit__.assert_called_once()

    def test_discovery_observes_hostname_changes_between_probes(self):
        m = self.module
        sock = MagicMock()
        sock.recvfrom.side_effect = [(m.PROBE_MAGIC, ('169.254.10.30', 40000)),
                                    (m.PROBE_MAGIC, ('192.0.2.30', 40001)), KeyboardInterrupt]
        with patch.object(m.socket, 'socket', return_value=sock), \
             patch.object(m.socket, 'gethostname', side_effect=['old-name', 'board-one', 'board-two']), \
             patch.object(m, '_get_version', return_value='test'), \
             patch.object(m, '_get_build_date', return_value='test'), \
             patch.object(m, '_mac_for_ip', return_value=''), \
             patch.object(m, '_primary_ip', side_effect=['169.254.10.20', '192.0.2.20']) as address:
            with self.assertRaises(KeyboardInterrupt):
                m.main()
        replies = [json.loads(call.args[0]) for call in sock.sendto.call_args_list]
        self.assertEqual([r['hostname'] for r in replies], ['board-one', 'board-two'])
        self.assertEqual([r['ip'] for r in replies], ['169.254.10.20', '192.0.2.20'])
        self.assertEqual([call.args[0] for call in address.call_args_list],
                         ['169.254.10.30', '192.0.2.30'])


@unittest.skipUnless(os.geteuid() == 0, 'run with sudo to verify real UID preservation')
class OverlayOwnershipTests(unittest.TestCase):
    def test_checkout_uid_does_not_replace_base_system_owners(self):
        with tempfile.TemporaryDirectory(prefix='mo62a-overlay-') as temp:
            base = Path(temp)
            source = base / 'sdk/board-support/rootfs-overlay'
            target = base / 'rootfs'
            (source / 'etc/NetworkManager/system-connections').mkdir(parents=True)
            (source / 'usr/local/bin').mkdir(parents=True)
            (source / 'usr/local/bin/demo').write_text('#!/bin/sh\nexit 0\n')
            (source / 'etc/hostname').write_text('board-test\n')
            (source / 'etc/NetworkManager/system-connections/end0.nmconnection').write_text('[connection]\n')
            (source / 'etc/alias').symlink_to('hostname')
            for p in [source, *source.rglob('*')]:
                os.chown(p, 1000, 1000, follow_symlinks=False)
            (target / 'etc').mkdir(parents=True)
            (target / 'var/lib/service').mkdir(parents=True)
            os.chown(target / 'var/lib/service', 123, 123)
            result = subprocess.run(['bash', '-c', '''
source "$1"
SDK_ROOT="$2/sdk"
ROOTFS_MNT="$2/rootfs"
install_rootfs_overlay
''', 'test', str(ROOT / 'bin/mo-62a-flash.sh'), str(base)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ['', 'etc', 'etc/hostname', 'usr/local/bin/demo', 'etc/alias']:
                self.assertEqual((target / name).lstat().st_uid, 0, name)
            self.assertEqual((target / 'var/lib/service').stat().st_uid, 123)
            self.assertEqual((source / 'etc').stat().st_uid, 1000)
            self.assertEqual((target / 'etc/alias').readlink(), Path('hostname'))
            self.assertEqual((target / 'etc/NetworkManager/system-connections/end0.nmconnection').stat().st_mode & 0o777, 0o600)
            self.assertTrue(os.access(target / 'usr/local/bin/demo', os.X_OK))


if __name__ == '__main__':
    unittest.main()
