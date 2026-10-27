#!/usr/bin/env bash
# Publish a draft release after its own image passed hardware validation.
# The record is validation/releases/<version>.json on master; it must name the
# draft's source commit and image SHA-256. Existing draft assets are unchanged
# except release.json and SHA256SUMS, which gain the validation result, and the
# new validation.json report.
set -euo pipefail
[[ $# == 1 && "$1" =~ ^V(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 1
version=$1
[[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] || exit 1
[[ "${GITHUB_ACTOR_ID:-}" == 49704703 && "${GH_REPO:-}" == inhandnet/Mo62A ]] || exit 1
record="validation/releases/$version.json"
[[ -f "$record" && ! -L "$record" ]] || { echo "Missing $record" >&2; exit 1; }
[[ $(gh release view "$version" --json isDraft --jq .isDraft) == true ]] || {
  echo 'Only a draft release can be validated and published.' >&2; exit 1;
}
work=$(mktemp -d)
gh release download "$version" --dir "$work" --pattern release.json --pattern SHA256SUMS
( cd "$work" && grep -E '  (release\.json)$' SHA256SUMS | sha256sum -c - )
python3 scripts/release.py --version "$version" --output "$work" --finalize --record "$record"
gh release upload "$version" --clobber "$work/release.json" "$work/SHA256SUMS" "$work/validation.json"
release_id=$(gh release view "$version" --json databaseId --jq .databaseId)
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid release ID' >&2; exit 1; }
gh api "repos/$GH_REPO/releases/$release_id" > "$work/remote.json"
python3 - "$work" <<'PY'
import hashlib, json, sys
from pathlib import Path
work = Path(sys.argv[1]); r = json.loads((work/'remote.json').read_text()); assert r['draft']
assets = {a['name']: a for a in r['assets']}
sums = dict(reversed(line.split('  ', 1)) for line in (work/'SHA256SUMS').read_text().splitlines())
for name, digest in sums.items():
    a = assets[name]
    assert a['state'] == 'uploaded' and a.get('digest') == 'sha256:' + digest, f'Remote checksum mismatch: {name}'
digest = hashlib.sha256((work/'SHA256SUMS').read_bytes()).hexdigest()
assert assets['SHA256SUMS'].get('digest') == 'sha256:' + digest
print(f'All {len(sums)} listed assets and SHA256SUMS match.')
PY
gh release edit "$version" --draft=false --latest
gh release view "$version" --json url --jq .url
