#!/usr/bin/env python3
"""Generate deterministic bilingual history and a downloadable release manifest."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from commit_policy import ROOT, check_range, git, load_yaml, parse_message

VALIDATION = ROOT / "validation" / "releases"
COMPANIONS = ("mo-tools", "mo-models", "mo-examples")
TEST_RESULTS = ("passed", "failed", "skipped")
VERSION = re.compile(r"^V(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
GROUPS = {
    "feat": ("Added", "新增"), "fix": ("Fixed", "修复"),
    "perf": ("Performance", "性能"), "docs": ("Documentation", "文档"),
    "refactor": ("Refactoring", "重构"), "test": ("Tests", "测试"),
    "build": ("Build", "构建"), "ci": ("Automation", "自动化"),
    "chore": ("Maintenance", "维护"), "revert": ("Reverted", "回退"),
    "sync": ("Synchronization", "同步"),
}


def settings():
    return load_yaml((ROOT / ".github/release-policy.yml").read_text())


def version_key(tag):
    match = VERSION.fullmatch(tag)
    if not match:
        raise ValueError(f"Invalid stable release tag: {tag}")
    return tuple(map(int, match.groups()))


def plain_markdown(value):
    return re.sub(r"([\\`*_{}\[\]()#+.!|<>])", r"\\\1", value)


def history(version, ref):
    config = settings()
    version_key(version)
    target = git("rev-parse", f"{ref}^{{commit}}")
    reachable = [t for t in git("tag", "--merged", target).splitlines() if VERSION.fullmatch(t)]
    if any(version_key(t) > version_key(version) for t in reachable):
        raise ValueError("A newer version already exists in this history")
    versions = sorted(set(reachable + [version]), key=version_key)
    versions = [t for t in versions if version_key(t) >= version_key(config["bootstrap_version"])]
    if not versions or versions[0] != config["bootstrap_version"]:
        raise ValueError("Missing bootstrap release V1.1.0 in the tag ancestry")
    result, previous = [], None
    for tag in versions:
        commit = target if tag == version else git("rev-parse", f"refs/tags/{tag}^{{commit}}")
        if tag in reachable and git("rev-parse", f"refs/tags/{tag}^{{commit}}") != commit:
            raise ValueError("Version tag does not point to the requested source commit")
        date = git("show", "-s", "--format=%cs", commit)
        notes = {}
        if previous is None:
            for lang in ("en", "zh"):
                notes[lang] = git("show", f"{commit}:release-notes/{tag}.{lang}.md")
        else:
            if subprocess.run(["git", "merge-base", "--is-ancestor", previous[1], commit]).returncode:
                raise ValueError("Release tags must follow a single ancestry")
            commits = check_range(previous[1], commit)
            if not commits:
                raise ValueError(f"No changes between {previous[0]} and {tag}")
            parsed = [(sha, parse_message(git("show", "-s", "--format=%B", sha))) for sha in commits]
            for lang, index in (("en", 0), ("zh", 1)):
                sections = []
                for kind, headings in GROUPS.items():
                    lines = []
                    for sha, item in parsed:
                        if item["type"] != kind:
                            continue
                        scope = f'**{item["scope"]}**: ' if item["scope"] else ""
                        breaking = ("**BREAKING:** " if lang == "en" else "**不兼容变更：** ") if item["breaking"] else ""
                        lines.append(f'- {breaking}{scope}{plain_markdown(item["messages"][lang])} '
                                     f'([{sha[:8]}](https://github.com/{config["repository"]}/commit/{sha}))')
                    if lines:
                        sections.append(f"### {headings[index]}\n\n" + "\n".join(lines))
                compare = f'https://github.com/{config["repository"]}/compare/{previous[0]}...{tag}'
                notes[lang] = "\n\n".join(sections) + f"\n\n[{'Full comparison' if lang == 'en' else '完整比较'}]({compare})"
        result.append({"version": tag, "date": date, "commit": commit,
                       "url": f'https://github.com/{config["repository"]}/releases/tag/{tag}', "notes": notes})
        previous = (tag, commit)
    return list(reversed(result))


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def generate(version, ref, output, image=None, raw_size=None, kernel=None, sbom=None):
    config = settings()
    entries = history(version, ref)
    output.mkdir(parents=True, exist_ok=True)
    base = f'https://github.com/{config["repository"]}/releases/download/{version}'
    for lang in ("en", "zh"):
        title = "Changelog" if lang == "en" else "更新日志"
        text = f"# {title}\n\n" + "\n\n".join(
            f'## {e["version"]} — {e["date"]}\n\n{e["notes"][lang]}' for e in entries)
        (output / f"CHANGELOG.{lang}.md").write_text(text + "\n")
    body = (f'## Mo62A {version}\n\n{entries[0]["notes"]["en"]}\n\n'
            f'<details>\n<summary>中文</summary>\n\n{entries[0]["notes"]["zh"]}\n\n</details>\n\n'
            f'[Full changelog — English]({base}/CHANGELOG.en.md) · '
            f'[完整更新日志 — 中文]({base}/CHANGELOG.zh.md)\n')
    (output / "release-body.md").write_text(body)
    if image is not None:
        expected_name = f'{config["image_prefix"]}-{version}.img.xz'
        if image.name != expected_name or image.is_symlink() or not image.is_file():
            raise ValueError("Image must be a regular file with the expected versioned .img.xz name")
        if not 0 < image.stat().st_size < config["asset_limit_bytes"]:
            raise ValueError("Compressed image exceeds the GitHub Release asset size limit")
        if not raw_size or raw_size != config["image_size_gib"] * 1024**3:
            raise ValueError("Unexpected raw image size")
        if not kernel:
            raise ValueError("Built kernel release is required")
        expected_sbom = f'{config["image_prefix"]}-{version}.spdx.json'
        if sbom is None or sbom.name != expected_sbom or sbom.is_symlink() or not sbom.is_file():
            raise ValueError("SBOM must be a regular file with the expected versioned .spdx.json name")
        document = json.loads(sbom.read_text())
        if document.get("spdxVersion") != "SPDX-2.3" or not document.get("packages"):
            raise ValueError("SBOM is not a non-empty SPDX 2.3 document")
        manifest = {
            "schemaVersion": 1, "board": "mo-62a", "version": version,
            "source": {"repository": config["repository"], "commit": entries[0]["commit"], "tag": version},
            "os": {"name": "Debian", "codename": "trixie", "desktop": "xfce", "kernel": kernel},
            "image": {"name": image.name, "url": f"{base}/{image.name}", "bytes": image.stat().st_size,
                      "uncompressedBytes": raw_size, "sha256": checksum(image), "compression": "xz",
                      "minimumCardBytes": max(config["minimum_card_bytes"], raw_size)},
            "rootfs": {"file": config["rootfs"], "sha256": config["rootfs_sha256"]},
            "checksums": f"{base}/SHA256SUMS",
            "sbom": {"name": sbom.name, "url": f"{base}/{sbom.name}", "format": "SPDX-2.3",
                     "sha256": checksum(sbom), "packages": len(document["packages"])},
            "changelog": {lang: f"{base}/CHANGELOG.{lang}.md" for lang in ("en", "zh")},
            "history": entries,
            # The tagged build is a draft. Hardware results are added by finalize()
            # after the draft image itself has been flashed and tested.
            "validation": {"build": True, "imageStructure": True, "hardwareBootTest": False},
        }
        (output / "release.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        assets = [image, sbom, output / "CHANGELOG.en.md", output / "CHANGELOG.zh.md", output / "release.json"]
        for asset in assets:
            if asset.stat().st_size >= config["asset_limit_bytes"]:
                raise ValueError(f"Asset too large: {asset.name}")
        (output / "SHA256SUMS").write_text("".join(f"{checksum(asset)}  {asset.name}\n" for asset in assets))
    return entries


def load_record(version, file=None):
    """Read and check the hardware validation record for one draft release."""
    file = Path(file) if file else VALIDATION / f"{version}.json"
    record = json.loads(file.read_text())
    required = {"version", "commit", "image", "kernel", "board", "date", "tester", "result", "tests", "companions"}
    missing = required - set(record)
    if missing:
        raise ValueError(f"Validation record is missing {sorted(missing)}")
    if record["version"] != version:
        raise ValueError("Validation record names a different version")
    if not re.fullmatch(r"[0-9a-f]{40}", record["commit"]):
        raise ValueError("Validation record commit must be a full SHA-1")
    if set(record["image"]) != {"name", "sha256"} or not re.fullmatch(r"[0-9a-f]{64}", record["image"]["sha256"]):
        raise ValueError("Validation record must name the tested image and its SHA-256")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", record["date"]):
        raise ValueError("Validation date must be YYYY-MM-DD")
    if set(record["companions"]) != set(COMPANIONS) or not all(
            VERSION.fullmatch(v) for v in record["companions"].values()):
        raise ValueError("Validation record must list the mo-tools, mo-models and mo-examples versions used")
    tests = record["tests"]
    if not tests or not all({"id", "item", "result"} <= set(t) and t["result"] in TEST_RESULTS for t in tests):
        raise ValueError("Each validation test needs id, item and a passed, failed or skipped result")
    if len({t["id"] for t in tests}) != len(tests):
        raise ValueError("Validation test ids must be unique")
    failed = any(t["result"] == "failed" for t in tests)
    if record["result"] not in ("passed", "failed") or (record["result"] == "passed") == failed:
        raise ValueError("Overall result must be failed exactly when a test failed")
    return record


def finalize(version, output, record_file=None):
    """Add hardware validation of the draft image to release.json and SHA256SUMS."""
    config = settings()
    manifest = json.loads((output / "release.json").read_text())
    record = load_record(version, record_file)
    if manifest["version"] != version or manifest["source"]["commit"] != record["commit"]:
        raise ValueError("Validation record does not describe this draft release source")
    if record["image"] != {"name": manifest["image"]["name"], "sha256": manifest["image"]["sha256"]}:
        raise ValueError("Validation record does not describe the draft image")
    if record["kernel"] != manifest["os"]["kernel"]:
        raise ValueError("Validation record kernel differs from the draft image")
    sums = {}
    for line in (output / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        sums[name] = digest
    if sums.get(manifest["image"]["name"]) != manifest["image"]["sha256"]:
        raise ValueError("Draft SHA256SUMS does not match the draft image")
    base = f'https://github.com/{config["repository"]}/releases/download/{version}'
    (output / "validation.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    counts = {r: sum(t["result"] == r for t in record["tests"]) for r in TEST_RESULTS}
    manifest["validation"].update({
        "hardwareBootTest": record["result"] == "passed",
        "hardware": {"result": record["result"], "date": record["date"], "board": record["board"],
                     "tester": record["tester"], "tests": counts, "companions": record["companions"],
                     "report": f"{base}/validation.json", "sha256": checksum(output / "validation.json")},
    })
    (output / "release.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    for name in ("release.json", "validation.json"):
        sums[name] = checksum(output / name)
    (output / "SHA256SUMS").write_text("".join(f"{d}  {n}\n" for n, d in sums.items()))
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--raw-size", type=int)
    parser.add_argument("--kernel")
    parser.add_argument("--sbom", type=Path)
    parser.add_argument("--finalize", action="store_true",
                        help="Add the validation record to the draft release.json in --output")
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    if args.finalize:
        finalize(args.version, args.output, args.record)
        return
    if args.ref.startswith("-"):
        raise ValueError("Invalid source ref")
    generate(args.version, args.ref, args.output, args.image, args.raw_size, args.kernel, args.sbom)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Release generation: {exc}")
