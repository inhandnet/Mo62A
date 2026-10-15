# Contributing

[中文](CONTRIBUTING.zh-CN.md)

## Pull requests

`master` is the default branch and accepts changes only through pull requests.
The `commit-message` and `validate-release` checks must pass against the latest
base branch; conversations must be resolved. Direct pushes, force pushes and
branch deletion are blocked, including for administrators. Rebase merging keeps
the validated commit messages intact. No minimum human approval count is imposed;
maintainers are responsible for reviewing changes before merging.

Do not include local build outputs, photographs containing identifiers, credentials
or internal planning documents in a pull request.

## Commit messages

Rules are configured in `.github/commit-policy.yml` and enforced by
`scripts/commit_policy.py`, the local hook and required GitHub Actions checks.
Use an English Conventional Commit subject (at most 72 characters), a blank
line, and a YAML body containing exactly `Message.en` and `Message.zh`:

```text
fix(image): include external drivers in offline images

Message:
  en: Include cryptodev when assembling an offline image.
  zh: 制作离线镜像时安装 cryptodev 驱动。
```

Use YAML quoting or `>-` for descriptions containing YAML punctuation such as
`: `. Allowed types: `feat`, `fix`, `docs`, `perf`, `refactor`, `test`, `build`,
`ci`, `chore`, `revert`, `sync`. An optional `!` before `:` marks a breaking change;
explain its migration impact in both summaries. Do not put private IP addresses
or internal hostnames in public messages. The PR title follows the subject rules.
All commits in a PR must pass; merge and fixup commits must be rebased before merging.

Install Python 3 and PyYAML (`sudo apt-get install python3-yaml` on Ubuntu), then:

```bash
git config core.hooksPath .githooks
git config commit.template .github/commit-template.txt
python3 -B -m unittest discover -s tests -v
```

## Release process

Only `weiyf1003` may create tags. Published tag targets cannot be changed or deleted.
After merging to `master`, use **Actions → Release image → Run workflow** to build
and verify a candidate without creating a release. Once it passes, create an
annotated stable tag on the approved `master` commit:

```bash
git fetch origin master --tags
git tag -a V1.1.1 origin/master -m "Mo62A V1.1.1"
git push origin V1.1.1
```

The tag triggers a clean GitHub-hosted build, image checks, checksum verification
and draft asset upload. The Release becomes public only after all five required
assets are uploaded and their server-reported digests match. Failed builds do not
publish a release. Retry a failed job without moving its tag; code fixes require
a new version tag. No long-lived publication token or self-hosted runner is needed.

The first **V1.1.0** notes are curated in `release-notes/`. Later entries include
every commit in `previous-tag..new-tag`, using `Message.en` and `Message.zh`.
Each release contains cumulative `CHANGELOG.en.md` and `CHANGELOG.zh.md`, plus
`release.json` for Software/Documentation consumers. See [RELEASES.md](RELEASES.md).
Historical published artifacts remain unchanged. Automated validation does not
claim that physical-board boot or peripherals have been tested.
