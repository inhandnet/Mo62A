"""Exercise publication ordering with a local GitHub CLI stub, never the network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GH_STUB = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['PUBLISH_TEST_DIR'])
a = sys.argv[1:]
with (p/'commands.jsonl').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[:2] == ['release', 'view']:
    if 'isDraft' in a:
        if not (p/'existing').exists(): sys.exit(1)
        print((p/'existing').read_text())
    elif 'databaseId' in a: print('42')
    elif 'url' in a: print('https://github.com/inhandnet/Mo62A/releases/tag/V1.1.0')
    else: sys.exit(2)
elif a[:2] == ['release', 'create']:
    assert '--draft' in a and '--verify-tag' in a
    assert a[a.index('--title') + 1] == 'V1.1.0'
    (p/'existing').write_text('true')
elif a[:2] == ['release', 'upload']:
    assert (p/'existing').read_text() == 'true'
elif a == ['api', 'repos/inhandnet/Mo62A/releases/42']:
    print((p/'remote.json').read_text())
elif a[:2] == ['release', 'edit']:
    assert '--draft=false' in a and '--latest' in a
    (p/'published').touch()
else: sys.exit(2)
'''


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mo62a-publish-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        dist = self.root/'dist'
        dist.mkdir()
        bindir = self.root/'bin'
        bindir.mkdir()
        stub = bindir/'gh'
        stub.write_text(GH_STUB)
        stub.chmod(0o755)
        image = 'mo62a-trixie-xfce-V1.1.0.img.xz'
        (dist/image).write_bytes(b'publication test fixture, not a real image')
        for lang in ('en', 'zh'):
            (dist/f'CHANGELOG.{lang}.md').write_text('# Test changelog\n')
        (dist/'release-body.md').write_text('Test release notes\n')
        (dist/'release.json').write_text(json.dumps({
            'version': 'V1.1.0', 'board': 'mo-62a', 'source': {'commit': '1'*40},
            'image': {'name': image}, 'validation': {'build': True, 'imageStructure': True}}))
        names = [image, 'CHANGELOG.en.md', 'CHANGELOG.zh.md', 'release.json']
        digest = lambda n: hashlib.sha256((dist/n).read_bytes()).hexdigest()
        (dist/'SHA256SUMS').write_text(''.join(f'{digest(n)}  {n}\n' for n in names))
        self.remote = {'draft': True, 'assets': [
            {'name': n, 'state': 'uploaded', 'size': (dist/n).stat().st_size,
             'digest': 'sha256:'+digest(n)} for n in names+['SHA256SUMS']]}
        self.env = {**os.environ, 'PATH': str(bindir)+os.pathsep+os.environ['PATH'],
                    'PUBLISH_TEST_DIR': str(self.root), 'RUNNER_TEMP': str(self.root),
                    'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/V1.1.0',
                    'GITHUB_ACTOR_ID': '49704703', 'GH_REPO': 'inhandnet/Mo62A',
                    'GITHUB_SHA': '1'*40}

    def run_publish(self):
        (self.root/'remote.json').write_text(json.dumps(self.remote))
        return subprocess.run(['bash', str(ROOT/'scripts/publish-release.sh'), 'V1.1.0'],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def test_create_verify_draft_by_id_then_publish(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue((self.root/'published').exists())
        calls = [json.loads(s) for s in (self.root/'commands.jsonl').read_text().splitlines()]
        self.assertLess(next(i for i,a in enumerate(calls) if a[0]=='api'),
                        next(i for i,a in enumerate(calls) if a[:2]==['release','edit']))

    def test_remote_digest_mismatch_never_publishes(self):
        self.remote['assets'][0]['digest'] = 'sha256:'+'0'*64
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertFalse((self.root/'published').exists())

    def test_published_release_is_not_overwritten(self):
        (self.root/'existing').write_text('false')
        self.assertNotEqual(self.run_publish().returncode, 0)
        calls = (self.root/'commands.jsonl').read_text()
        self.assertNotIn('upload', calls)
        self.assertNotIn('edit', calls)

    def test_unapproved_actor_is_rejected_before_network(self):
        self.env['GITHUB_ACTOR_ID'] = '123'
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertFalse((self.root/'commands.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
