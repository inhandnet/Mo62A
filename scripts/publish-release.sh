#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && "$1" =~ ^V(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 1
version=$1
[[ "${GITHUB_EVENT_NAME:-}" == push && "${GITHUB_REF:-}" == "refs/tags/$version" ]] || exit 1
[[ "${GITHUB_ACTOR_ID:-}" == 49704703 && "${GH_REPO:-}" == inhandnet/Mo62A ]] || exit 1
cd dist
sha256sum -c SHA256SUMS
python3 - "$version" <<'PY'
import json, os, sys
from pathlib import Path
m=json.loads(Path('release.json').read_text())
assert m['version']==sys.argv[1] and m['board']=='mo-62a'
assert m['source']['commit']==os.environ['GITHUB_SHA']
assert m['image']['name']==f'mo62a-trixie-xfce-{sys.argv[1]}.img.xz'
assert m['validation']['build'] and m['validation']['imageStructure']
for f in [m['image']['name'], m['sbom']['name'], 'SHA256SUMS', 'CHANGELOG.en.md', 'CHANGELOG.zh.md', 'release.json']:
    p=Path(f)
    assert p.is_file() and not p.is_symlink() and 0<p.stat().st_size<2**31
PY
if gh release view "$version" --json isDraft --jq .isDraft > "$RUNNER_TEMP/mo62a-release-state" 2>/dev/null; then
  [[ $(< "$RUNNER_TEMP/mo62a-release-state") == true ]] || {
    echo 'A published release already exists; refusing to replace immutable assets.' >&2; exit 1;
  }
else
  gh release create "$version" --verify-tag --target "$GITHUB_SHA" --draft \
    --title "$version" --notes-file release-body.md
fi
# Retrying an incomplete draft is safe; published releases are never overwritten.
gh release upload "$version" --clobber "mo62a-trixie-xfce-$version.img.xz" \
  "mo62a-trixie-xfce-$version.spdx.json" SHA256SUMS CHANGELOG.en.md CHANGELOG.zh.md release.json
# The tag endpoint is for published releases. Resolve a draft through gh, then
# inspect it by numeric release ID before making it public.
release_id=$(gh release view "$version" --json databaseId --jq .databaseId)
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid release ID' >&2; exit 1; }
gh api "repos/$GH_REPO/releases/$release_id" > "$RUNNER_TEMP/mo62a-release-assets.json"
python3 - "$RUNNER_TEMP/mo62a-release-assets.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['draft']
assets={a['name']: a for a in r['assets']}
m=json.loads(Path('release.json').read_text())
for name in [m['image']['name'], m['sbom']['name'], 'SHA256SUMS', 'CHANGELOG.en.md', 'CHANGELOG.zh.md', 'release.json']:
    a=assets[name]; p=Path(name)
    assert a['state']=='uploaded' and a['size']==p.stat().st_size
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024), b''): h.update(block)
    assert a.get('digest')=='sha256:'+h.hexdigest(), f'Remote checksum mismatch: {name}'
print('All uploaded assets match their local SHA-256 checksums.')
PY
# The tag build stops at a verified draft. The draft image is flashed and
# tested; scripts/publish-validated.sh adds that record and publishes.
echo "Draft $version is ready for hardware validation; it is not public yet."
