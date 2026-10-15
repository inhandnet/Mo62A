#!/usr/bin/env python3
"""One commit policy shared by local hooks, PR checks and release generation."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str) or key in result:
            raise ValueError("YAML keys must be unique strings")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def load_yaml(text):
    return yaml.load(text, Loader=UniqueLoader)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def policy():
    return load_yaml((ROOT / ".github/commit-policy.yml").read_text())


def check_title(title, config=None):
    config = config or policy()
    match = re.fullmatch(r"([a-z]+)(?:\(([a-z0-9][a-z0-9/-]*)\))?(!)?: ([a-z].*)", title)
    if not match or match[1] not in config["types"]:
        raise ValueError("Use '<type>(<scope>): <lowercase English subject>'")
    if len(title) > config["header_max_length"] or title.endswith("."):
        raise ValueError("Subject must be at most 72 characters and have no final period")
    if not title.isascii():
        raise ValueError("Use an English ASCII subject; Chinese belongs in Message.zh")
    return {"type": match[1], "scope": match[2], "breaking": bool(match[3])}


def parse_message(text, config=None):
    config = config or policy()
    lines = text.strip().splitlines()
    if len(lines) < 4 or lines[1].strip():
        raise ValueError("Leave a blank line after the subject, then add YAML Message.en / Message.zh")
    result = check_title(lines[0], config)
    data = load_yaml("\n".join(lines[2:]))
    if not isinstance(data, dict) or set(data) != {config["body_key"]}:
        raise ValueError("Commit body must contain only the YAML Message mapping")
    messages = data[config["body_key"]]
    if not isinstance(messages, dict) or set(messages) != set(config["required_languages"]):
        raise ValueError("Message must contain exactly en and zh")
    for lang, message in messages.items():
        if not isinstance(message, str) or not 1 <= len(message.strip()) <= config["summary_max_length"]:
            raise ValueError(f"Message.{lang} must be a non-empty string of at most 500 characters")
        if any(ord(c) < 32 and c not in "\n\t" for c in message):
            raise ValueError("Control characters are not allowed")
    if not re.search(r"[A-Za-z]", messages["en"]) or re.search(r"[\u4e00-\u9fff]", messages["en"]):
        raise ValueError("Message.en must contain an English summary")
    if not re.search(r"[\u4e00-\u9fff]", messages["zh"]):
        raise ValueError("Message.zh must contain a Chinese summary")
    if re.search(r"(?<![\d.])(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?!\d|\.\d)|inhand\.design|gitlab\.inhand", text, re.I):
        raise ValueError("Do not include internal network addresses or domains in public commits")
    result["messages"] = {lang: " ".join(value.split()) for lang, value in messages.items()}
    return result


def check_range(base, head):
    for ref in (base, head):
        if not re.fullmatch(r"[0-9a-f]{40}", ref):
            raise ValueError("Commit range endpoints must be full SHA-1 IDs")
    commits = git("rev-list", "--reverse", f"{base}..{head}").splitlines()
    for commit in commits:
        if len(git("rev-list", "--parents", "-n", "1", commit).split()) > 2:
            raise ValueError(f"Merge commit {commit} is not allowed; rebase the branch")
        try:
            parse_message(git("show", "-s", "--format=%B", commit))
        except (ValueError, yaml.YAMLError) as exc:
            raise ValueError(f"{commit[:12]}: {exc}") from exc
    return commits


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--file", type=Path)
    group.add_argument("--title")
    group.add_argument("--range", nargs=2, metavar=("BASE_SHA", "HEAD_SHA"))
    args = parser.parse_args()
    if args.file:
        parse_message(args.file.read_text())
    elif args.title:
        check_title(args.title)
    else:
        print(f"Validated {len(check_range(*args.range))} commits")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, yaml.YAMLError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Commit policy: {exc}")
