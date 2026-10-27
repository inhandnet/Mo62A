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
    import hashlib
    remote = json.loads((p/'remote.json').read_text())
    for f in (a[3:] if (p/'track-uploads').exists() else []):
        if f.startswith('-'): continue
        f = Path(f); d = 'sha256:' + hashlib.sha256(f.read_bytes()).hexdigest()
        remote['assets'] = [x for x in remote['assets'] if x['name'] != f.name] + [
            {'name': f.name, 'state': 'uploaded', 'size': f.stat().st_size, 'digest': d}]
    (p/'remote.json').write_text(json.dumps(remote))
elif a[:2] == ['release', 'download']:
    out = Path(a[a.index('--dir') + 1])
    for i, x in enumerate(a):
        if x == '--pattern': (out/a[i+1]).write_bytes((p/'dist'/a[i+1]).read_bytes())
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
        sbom = 'mo62a-trixie-xfce-V1.1.0.spdx.json'
        (dist/sbom).write_text('{"spdxVersion": "SPDX-2.3"}\n')
        (dist/'release.json').write_text(json.dumps({
            'version': 'V1.1.0', 'board': 'mo-62a', 'source': {'commit': '1'*40},
            'image': {'name': image}, 'sbom': {'name': sbom}, 'validation': {'build': True, 'imageStructure': True}}))
        names = [image, sbom, 'CHANGELOG.en.md', 'CHANGELOG.zh.md', 'release.json']
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

    def test_tag_build_verifies_the_draft_and_leaves_it_unpublished(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertFalse((self.root/'published').exists())
        calls = [json.loads(s) for s in (self.root/'commands.jsonl').read_text().splitlines()]
        self.assertTrue(any(a[0] == 'api' for a in calls))
        self.assertFalse(any(a[:2] == ['release', 'edit'] for a in calls))

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


class PublishValidatedTests(PublishTests):
    def setUp(self):
        super().setUp()
        import shutil, sys
        sys.path.insert(0, str(ROOT/'scripts'))
        import release
        dist = self.root/'dist'
        manifest = json.loads((dist/'release.json').read_text())
        manifest.update({'source': {'repository': 'inhandnet/Mo62A', 'commit': '1'*40, 'tag': 'V1.1.0'},
                         'os': {'kernel': '6.12-test'}})
        manifest['image']['sha256'] = release.checksum(dist/manifest['image']['name'])
        (dist/'release.json').write_text(json.dumps(manifest))
        names = [manifest['image']['name'], 'mo62a-trixie-xfce-V1.1.0.spdx.json', 'CHANGELOG.en.md', 'CHANGELOG.zh.md', 'release.json']
        (dist/'SHA256SUMS').write_text(''.join(f'{release.checksum(dist/n)}  {n}\n' for n in names))
        self.remote = {'draft': True, 'assets': [
            {'name': n, 'state': 'uploaded', 'size': (dist/n).stat().st_size,
             'digest': 'sha256:'+release.checksum(dist/n)} for n in names+['SHA256SUMS']]}
        record = {'version': 'V1.1.0', 'commit': '1'*40,
                  'image': {'name': manifest['image']['name'], 'sha256': manifest['image']['sha256']},
                  'kernel': '6.12-test', 'board': 'Mo62A', 'date': '2026-10-27', 'tester': 'lab', 'result': 'passed',
                  'companions': {'mo-tools': 'V1.0.0', 'mo-models': 'V1.0.0', 'mo-examples': 'V1.0.0'},
                  'tests': [{'id': 'boot', 'item': 'Boot', 'result': 'passed'}]}
        shutil.copytree(ROOT/'scripts', self.root/'scripts'); shutil.copytree(ROOT/'.github', self.root/'.github')
        (self.root/'validation/releases').mkdir(parents=True)
        (self.root/'validation/releases/V1.1.0.json').write_text(json.dumps(record))
        (self.root/'existing').write_text('true')
        (self.root/'track-uploads').touch()
        self.env.update({'GITHUB_EVENT_NAME': 'workflow_dispatch'})

    def run_validated(self):
        (self.root/'remote.json').write_text(json.dumps(self.remote))
        return subprocess.run(['bash', 'scripts/publish-validated.sh', 'V1.1.0'],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def test_validated_draft_is_published_with_its_report(self):
        result = self.run_validated()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue((self.root/'published').exists())
        remote = json.loads((self.root/'remote.json').read_text())
        self.assertIn('validation.json', {a['name'] for a in remote['assets']})

    def test_record_for_another_image_never_publishes(self):
        path = self.root/'validation/releases/V1.1.0.json'
        record = json.loads(path.read_text()); record['image']['sha256'] = '0'*64
        path.write_text(json.dumps(record))
        self.assertNotEqual(self.run_validated().returncode, 0)
        self.assertFalse((self.root/'published').exists())

    def test_published_release_cannot_be_validated_again(self):
        (self.root/'existing').write_text('false')
        self.assertNotEqual(self.run_validated().returncode, 0)
        self.assertNotIn('upload', (self.root/'commands.jsonl').read_text())

    # Inherited tag-build tests are covered by PublishTests.
    test_tag_build_verifies_the_draft_and_leaves_it_unpublished = None
    test_remote_digest_mismatch_never_publishes = None
    test_published_release_is_not_overwritten = None
    test_unapproved_actor_is_rejected_before_network = None


if __name__ == '__main__':
    unittest.main()
