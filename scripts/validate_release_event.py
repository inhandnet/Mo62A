#!/usr/bin/env python3
"""Fail closed before any expensive release build."""
import os
import subprocess
import sys

from commit_policy import git
from release import settings, version_key


def main():
    config = settings()
    version_key(os.environ["VERSION"])
    if os.environ.get("GITHUB_REPOSITORY") != config["repository"]:
        raise ValueError("Unexpected repository")
    if os.environ.get("ACTOR_ID") != str(config["publisher_id"]):
        raise ValueError("Only the configured release owner may start a build")
    if os.environ.get("TRIGGERING_ACTOR") != config["publisher_login"]:
        raise ValueError("Only the configured release owner may rerun a build")
    head = git("rev-parse", "HEAD")
    subprocess.run(["git", "merge-base", "--is-ancestor", head,
                    f'refs/remotes/origin/{config["branch"]}'], check=True)
    if os.environ["EVENT"] == "push":
        tag = os.environ["VERSION"]
        if os.environ.get("GITHUB_REF") != f"refs/tags/{tag}":
            raise ValueError("A tag push is required for publication")
        if git("cat-file", "-t", f"refs/tags/{tag}") != "tag":
            raise ValueError("Use an annotated tag (git tag -a)")
        if git("rev-parse", f"refs/tags/{tag}^{{commit}}") != head:
            raise ValueError("Tag/source mismatch")
    elif os.environ["EVENT"] != "workflow_dispatch":
        raise ValueError("Unsupported build event")
    print(f'Validated {os.environ["VERSION"]} at {head}')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Release gate: {exc}")
