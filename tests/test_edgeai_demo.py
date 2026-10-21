"""Exercise camera status without opening any real hardware nodes."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class CameraStatusTests(unittest.TestCase):
    def test_status_excludes_internal_nodes_and_succeeds_with_usb_camera(self):
        source = (Path(__file__).resolve().parents[1] /
                  'board-support/rootfs-overlay/usr/local/bin/edgeai-demo').read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'dev').mkdir()
            (root / 'sys').mkdir()

            def add_node(number, name):
                (root / 'dev' / f'video{number}').touch()
                node = root / 'sys' / f'video{number}'
                node.mkdir()
                (node / 'name').write_text(name)

            for number, name in enumerate([
                'C&M Wave5 VPU decoder', 'C&M Wave5 VPU encoder',
                '30102000.ticsi2rx context 0', 'e5010 jpeg encoder',
            ]):
                add_node(number, name)
            script = root / 'edgeai-demo'
            script.write_text(source.replace('/dev/video*', str(root / 'dev/video*'))
                              .replace('/sys/class/video4linux/', str(root / 'sys') + '/')
                              .replace('/etc/csi-camera/csi-camera.conf', str(root / 'no-config')))

            def status():
                return subprocess.run(['bash', str(script), 'status'],
                                      text=True, capture_output=True, check=True).stdout

            self.assertIn('None found', status())
            self.assertNotIn('Wave5', status())
            add_node(9, 'USB Test Camera')
            output = status()
            self.assertIn('USB Test Camera', output)
            self.assertNotIn('Wave5', output)
            self.assertNotIn('None found', output)


if __name__ == '__main__':
    unittest.main()
