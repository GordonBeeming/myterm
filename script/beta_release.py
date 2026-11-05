#!/usr/bin/env python3
"""Freeze a main snapshot and publish its immutable beta after both platforms pass."""

import json
import hashlib
import os
from pathlib import Path
import re
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
        if error.code == 404 and path.startswith("git/ref/tags/"):
            return None
        raise


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def find_release(tag):
    """Include drafts visible to the token so retries cannot create duplicate drafts."""
    page = 1
    while True:
        releases = github(f"releases?per_page=100&page={page}")
        for release in releases:
            if release["tag_name"] == tag:
                return release
        if len(releases) < 100:
            return None
        page += 1


def verify_tag(tag, sha, required=False):
    """Resolve lightweight and nested annotated tags instead of trusting target_commitish."""
    reference = github(f"git/ref/tags/{tag}")
    if reference is None:
        if required:
            raise RuntimeError("Published beta tag is missing")
        return
    target = reference["object"]
    for _ in range(10):
        if target["type"] == "commit":
            if target["sha"] != sha:
                raise RuntimeError(f"Existing tag {tag} points to a different source")
            return
        if target["type"] != "tag":
            break
        target = github(f"git/tags/{target['sha']}")["object"]
    raise RuntimeError("Beta tag does not resolve to a commit")


def metadata(release, sha, version, tag):
    """Validate the original batch identity before reusing a draft or published artifact."""
    match = re.search(r"<!-- myterm-beta: (.+) -->", release.get("body") or "")
    if match is None or not release["prerelease"]:
        raise RuntimeError("Existing release lacks beta batch metadata")
    value = json.loads(match.group(1))
    if any(value.get(key) != expected for key, expected in
           (("sha", sha), ("version", version), ("tag", tag))):
        raise RuntimeError("Existing release belongs to a different beta batch")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", value.get("build", "")) \
            or not re.fullmatch(r"[1-9][0-9]*", value.get("run_id", "")) \
            or not re.fullmatch(r"[0-9a-f]{64}", value.get("sha256", "")):
        raise RuntimeError("Existing beta build metadata is invalid")
    return value


def verify_asset(release, name, digest):
    """Reject partial or mismatched uploads; never replace a published or draft asset."""
    assets = release["assets"]
    if len(assets) != 1 or assets[0]["name"] != name \
            or assets[0].get("state") != "uploaded" or assets[0].get("digest") != f"sha256:{digest}":
        raise RuntimeError("Existing beta DMG does not match the completed batch")


def prepare():
    """Pin all jobs to one verified commit, skipping an already published snapshot."""
    sha = git("rev-parse", "HEAD")
    commit = github(f"commits/{sha}")
    if not commit["commit"]["verification"]["verified"]:
        raise RuntimeError("Beta source must have a verified signature")
    version = f"0.0.{git('rev-list', '--count', 'HEAD')}"
    tag = f"v{version}-beta"
    verify_tag(tag, sha)
    existing = find_release(tag)
    # This workflow starts after the previous TestFlight workflow's build sequence.
    build_number = str(1000 + int(os.environ["GITHUB_RUN_NUMBER"]))
    if int(build_number) > 9999:
        raise RuntimeError("TestFlight build sequence requires a new versioning range before exceeding four digits")
    run_id = os.environ["GITHUB_RUN_ID"]
    if existing is not None:
        original = metadata(existing, sha, version, tag)
        run_id, build_number = original["run_id"], original["build"]
        if not existing["draft"]:
            verify_tag(tag, sha, required=True)
            verify_asset(existing, f"myterm-{version}-aarch64.dmg", original["sha256"])
    values = dict(sha=sha, version=version, tag=tag,
                  publish=str(existing is None or existing["draft"]).lower(), build_number=build_number,
                  resume=str(existing is not None and existing["draft"]).lower(), artifact_run_id=run_id)
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
    run_id = os.environ["BETA_ARTIFACT_RUN_ID"]
    dmg = Path(f"dist/myterm-{version}-aarch64.dmg")
    if not dmg.is_file():
        raise RuntimeError(f"Signed beta DMG is missing: {dmg}")
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    batch = dict(sha=sha, version=version, tag=tag, build=build, run_id=run_id, sha256=digest)
    verify_tag(tag, sha)
    existing = find_release(tag)
    if existing is not None:
        if metadata(existing, sha, version, tag) != batch:
            raise RuntimeError("Retry must use the original batch artifact and TestFlight build")
        if not existing["draft"]:
            verify_tag(tag, sha, required=True)
            verify_asset(existing, dmg.name, digest)
            return
    notes = Path(os.environ["RUNNER_TEMP"]) / "beta-notes.md"
    notes.write_text(
        f"Automatic beta from `main` at `{sha}`.\n\n"
        f"Companion TestFlight build: **{build}** (Apple processing may still be pending).\n\n"
        "The macOS app and DMG are signed, notarized, and stapled. "
        "Download the DMG to use this beta channel; stable Homebrew installs stay on stable releases.\n",
        encoding="utf-8",
    )
    with notes.open("a", encoding="utf-8") as output:
        output.write(f"\n<!-- myterm-beta: {json.dumps(batch, sort_keys=True)} -->\n")
    if existing is None:
        subprocess.run(["gh", "release", "create", tag, "--target", sha,
                        "--draft", "--prerelease", "--latest=false", "--title", f"MyTerm {version} Beta",
                        "--notes-file", str(notes)], check=True)
    elif len(existing["assets"]) == 1:
        asset = existing["assets"][0]
        # GitHub can leave an empty starter record after a failed upload. It has no
        # artifact bytes to preserve; completed or nonempty assets are never replaced.
        if asset["name"] == dmg.name and asset.get("state") == "starter" and asset.get("size") == 0:
            subprocess.run(["gh", "api", "--method", "DELETE",
                            f"repos/{os.environ['GITHUB_REPOSITORY']}/releases/assets/{asset['id']}"], check=True)
            existing = dict(existing, assets=[])
    if existing is None or not existing["assets"]:
        subprocess.run(["gh", "release", "upload", tag, str(dmg)], check=True)
    uploaded = find_release(tag)
    if uploaded is None or metadata(uploaded, sha, version, tag) != batch:
        raise RuntimeError("Uploaded draft no longer matches the beta batch")
    verify_asset(uploaded, dmg.name, digest)
    verify_tag(tag, sha)
    subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--latest=false"], check=True)
    verify_tag(tag, sha, required=True)


if __name__ == "__main__":
    {"prepare": prepare, "publish": publish}[sys.argv[1]]()
