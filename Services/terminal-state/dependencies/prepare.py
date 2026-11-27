#!/usr/bin/env python3
"""Prepare the locked sources for the headless WezTerm dependency."""

import fcntl
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
DESTINATION = HERE.parent / ".engine"
PATCH = HERE / "wezterm.patch"
SOURCES = {
    "wezterm": (
        "wezterm/wezterm", "458a100c1bf4134d36cb5c42dd90e4c8266d9e1a",
        "e711e5d63a70445f03650f09948d99a3d1812442a9bc50648f052354c116ec44",
    ),
    "finl": (
        "wez/finl_unicode", "a1892f26245529f2ef3877a9ebd610c96cec07a6",
        "181c938f6150fa392deebe3f8134a30f07e9b4ab13cf21ce620e4dad90dde311",
    ),
}


def extract(name, directory):
    repo, revision, checksum = SOURCES[name]
    archive = directory / f"{name}.tar.gz"
    subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "90",
         f"https://codeload.github.com/{repo}/tar.gz/{revision}", "--output", str(archive)],
        check=True,
    )
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
            raise RuntimeError(f"Source archive digest mismatch for {repo} at {revision}")
    output = directory / name
    with tarfile.open(archive) as source:
        root = source.next()
        if root is None or not root.isdir():
            raise RuntimeError(f"Missing archive root for {repo}")
        prefix = root.name + "/"
        for member in source:
            if member.name == root.name:
                continue
            if not member.name.startswith(prefix):
                raise RuntimeError(f"Unexpected archive path {member.name}")
            member.name = member.name[len(prefix):]
            source.extract(member, output, filter="data")


def prepare():
    stamp = hashlib.sha256(Path(__file__).read_bytes() + PATCH.read_bytes()).hexdigest()
    DESTINATION.mkdir(exist_ok=True)
    with (DESTINATION / "prepare.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        marker = DESTINATION / "source.sha256"
        if marker.exists() and marker.read_text().strip() == stamp and all(
            (DESTINATION / name / "Cargo.toml").is_file() for name in SOURCES
        ):
            return
        with tempfile.TemporaryDirectory(dir=DESTINATION) as temporary:
            staging = Path(temporary)
            for name in SOURCES:
                extract(name, staging)
            wezterm = staging / "wezterm"
            workspace = wezterm / "Cargo.toml"
            text, count = re.subn(
                r"finl_unicode = \{[^\n]+",
                'finl_unicode = { path = "../finl", default-features = false, '
                'features = ["categories", "grapheme_clusters"] }',
                workspace.read_text(),
            )
            if count != 1:
                raise RuntimeError("WezTerm finl_unicode declaration changed")
            workspace.write_text(text)
            subprocess.run(
                ["patch", "--batch", "--forward", "--fuzz=0", "--silent", "-p1", "-i", str(PATCH)],
                check=True, cwd=wezterm,
            )
            marker.unlink(missing_ok=True)
            for name in SOURCES:
                destination = DESTINATION / name
                if destination.exists():
                    shutil.rmtree(destination)
                (staging / name).rename(destination)
            staged_marker = staging / marker.name
            staged_marker.write_text(stamp + "\n")
            staged_marker.rename(marker)


if __name__ == "__main__":
    prepare()
