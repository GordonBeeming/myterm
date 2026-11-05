#!/usr/bin/env python3
"""Freeze a main snapshot and publish its immutable beta after both platforms pass."""

import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request


def github(path):
    """Return API JSON; only a missing release is an expected absence."""
    request = urllib.request.Request(
        f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/{path}",
        headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                 "Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and path.startswith("releases/tags/"):
            return None
        raise


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def prepare():
    """Pin all jobs to one verified commit, skipping an already published snapshot."""
    sha = git("rev-parse", "HEAD")
    commit = github(f"commits/{sha}")
    if not commit["commit"]["verification"]["verified"]:
        raise RuntimeError("Beta source must have a verified signature")
    version = f"0.0.{git('rev-list', '--count', 'HEAD')}"
    tag = f"v{version}-beta"
    existing = github(f"releases/tags/{tag}")
    if existing is not None and (existing["target_commitish"] != sha or not existing["prerelease"]
                                 or existing["draft"] or not existing["assets"]):
        raise RuntimeError("Existing beta tag belongs to a different source or channel")
    # This workflow starts after the previous TestFlight workflow's build sequence.
    build_number = str(10000 + int(os.environ["GITHUB_RUN_NUMBER"]))
    values = dict(sha=sha, version=version, tag=tag,
                  publish=str(existing is None).lower(), build_number=build_number)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    print(json.dumps(values))


def publish():
    """Create an immutable prerelease without changing the stable latest release or tap."""
    sha = os.environ["BETA_SOURCE_SHA"]
    version = os.environ["BETA_VERSION"]
    tag = os.environ["BETA_TAG"]
    build = os.environ["BETA_BUILD_NUMBER"]
    dmg = Path(f"dist/myterm-{version}-aarch64.dmg")
    if not dmg.is_file():
        raise RuntimeError(f"Signed beta DMG is missing: {dmg}")
    notes = Path(os.environ["RUNNER_TEMP"]) / "beta-notes.md"
    notes.write_text(
        f"Automatic beta from `main` at `{sha}`.\n\n"
        f"Companion TestFlight build: **{build}** (Apple processing may still be pending).\n\n"
        "The macOS app and DMG are signed, notarized, and stapled. "
        "Download the DMG to use this beta channel; stable Homebrew installs stay on stable releases.\n",
        encoding="utf-8",
    )
    subprocess.run(["gh", "release", "create", tag, str(dmg), "--target", sha,
                    "--draft", "--prerelease", "--latest=false", "--title", f"MyTerm {version} Beta",
                    "--notes-file", str(notes)], check=True)
    subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--latest=false"], check=True)


if __name__ == "__main__":
    {"prepare": prepare, "publish": publish}[sys.argv[1]]()
