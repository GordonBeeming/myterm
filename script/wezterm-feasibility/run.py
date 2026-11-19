"""Throwaway, local macOS feasibility gate; mismatches are findings, not CI passes."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile

WEZTERM = "458a100c1bf4134d36cb5c42dd90e4c8266d9e1a"
FINL = "a1892f26245529f2ef3877a9ebd610c96cec07a6"
ROOT = Path(__file__).resolve().parents[2]


def unpack(repo, revision, destination):
    if destination.exists():
        raise RuntimeError(f"source already exists; choose a fresh output directory: {destination}")
    archive = destination.with_suffix(".tar.gz")
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "90",
                    f"https://codeload.github.com/{repo}/tar.gz/{revision}", "--output", str(archive)],
                   check=True, timeout=100)
    destination.mkdir()
    with tarfile.open(archive) as source:
        members = source.getmembers()
        prefix = members[0].name.split("/")[0] + "/"
        for member in members:
            if not member.name.startswith(prefix):
                continue
            member.name = member.name[len(prefix):]
            if member.name:
                source.extract(member, destination, filter="data")


def run(command, log, *, data=None, env=None):
    with log.open("wb") as stderr:
        result = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=stderr,
                                env=env, check=False, timeout=300)
    if result.returncode:
        log.with_suffix(log.suffix + ".stdout").write_bytes(result.stdout)
        result.check_returncode()
    return result.stdout


def compare(swift, candidate):
    if set(swift) != set(candidate):
        raise RuntimeError("trace names differ")
    result = {}
    fields = ["cells", "styles", "cursor", "alt", "history", "replies"]
    for name, baseline in swift.items():
        a, b = baseline["snapshots"], candidate[name]["snapshots"]
        if len(a) != len(b):
            raise RuntimeError(f"snapshot count differs: {name}")
        differences = [{"event": i, "fields": [f for f in fields if x[f] != y[f]]}
                       for i, (x, y) in enumerate(zip(a, b)) if any(x[f] != y[f] for f in fields)]
        if not baseline["checkpointChecks"] or not all(baseline["checkpointChecks"]):
            raise RuntimeError(f"SwiftTerm checkpoint positive control failed: {name}")
        result[name] = {"differences": differences, "projectionMatches": not differences,
                        "swiftCheckpointChecks": len(baseline["checkpointChecks"]),
                        "rustToSwiftReconnect": "not implemented"}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("this gate intentionally runs only on native macOS")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    unpack("wezterm/wezterm", WEZTERM, out / "source")
    unpack("wez/finl_unicode", FINL, out / "finl")
    workspace = out / "source/Cargo.toml"
    text, count = re.subn(r'finl_unicode = \{[^\n]+',
        f'finl_unicode = {{ path = "{out / "finl"}", default-features=false, features=["categories", "grapheme_clusters"]}}', workspace.read_text())
    if count != 1:
        raise RuntimeError("upstream finl dependency declaration changed")
    workspace.write_text(text)
    probe = out / "probe"
    probe.mkdir()
    prototype = Path(__file__).resolve().parent
    manifest = (prototype / "Cargo.toml.in").read_text().replace("@WEZTERM_SOURCE@", str(out / "source")).replace("@PROTOTYPE_SOURCE@", str(prototype))
    (probe / "Cargo.toml").write_text(manifest)
    shutil.copyfile(prototype / "Cargo.lock", probe / "Cargo.lock")
    run(["cargo", "+1.99.1", "build", "--locked", "--manifest-path", str(probe / "Cargo.toml")], out / "build.log")
    test_result = run(["cargo", "+1.99.1", "test", "--locked", "--manifest-path", str(probe / "Cargo.toml")], out / "test.log")
    (out / "test-stdout.log").write_bytes(test_result)
    run(["swift", "build", "--package-path", str(ROOT / "script/native-comparison/swift"),
         "--scratch-path", str(out / "swift-build")], out / "swift-build.log")
    fixtures = (ROOT / "script/native-comparison/fixtures.json").read_bytes()
    baseline = run([str(out / "swift-build/debug/Baseline")], out / "swift-stderr.log", data=fixtures)
    (out / "swift-traces.json").write_bytes(baseline)
    swift = json.loads(baseline)
    geometry = {tuple(s["cellPixels"]) for t in swift.values() for s in t["snapshots"]}
    if len(geometry) != 1:
        raise RuntimeError(f"inconsistent SwiftTerm cell geometry: {geometry}")
    width, height = geometry.pop()
    env = dict(os.environ, CELL_WIDTH=str(width), CELL_HEIGHT=str(height))
    candidate = run(["/usr/bin/time", "-l", str(probe / "target/debug/wezterm-feasibility")],
                    out / "probe-time.log", data=fixtures, env=env)
    (out / "wezterm-traces.json").write_bytes(candidate)
    (out / "comparison.json").write_text(json.dumps(compare(swift, json.loads(candidate)), indent=2) + "\n")
    invalid = {"malformed-json": b"{", "zero-resize": b'[{"name":"invalid","events":[{"resize":[0,6]}]}]',
               "oversize-resize": b'[{"name":"invalid","events":[{"resize":[1001,6]}]}]',
               "negative-resize": b'[{"name":"invalid","events":[{"resize":[-1,6]}]}]',
               "oversize-input": b" " * (4 * 1024 * 1024 + 1)}
    failures = {}
    for name, payload in invalid.items():
        result = subprocess.run([str(probe / "target/debug/wezterm-feasibility")], input=payload,
                                capture_output=True, timeout=10, env=env)
        if result.returncode == 0 or result.stdout or not result.stderr:
            raise RuntimeError(f"invalid input did not fail with diagnostics: {name}")
        failures[name] = {"exitCode": result.returncode, "stderr": result.stderr.decode().strip()}
    (out / "failure-cases.json").write_text(json.dumps(failures, indent=2) + "\n")
    metadata = {"timestampUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "os": platform.platform(), "machine": platform.machine(), "wezterm": WEZTERM,
                "finl": FINL, "cellPixels": [width, height], "fixtureSha256": hashlib.sha256(fixtures).hexdigest(),
                "scope": "local macOS engine projection only; reconnect is unproven",
                "replyCapture": "FIFO paste barrier into capture-only writer; marker stripped before snapshots; no PTY",
                "probeSourceSha256": hashlib.sha256((prototype / "main.rs").read_bytes()).hexdigest(),
                "baselineSourceSha256": hashlib.sha256((ROOT / "script/native-comparison/swift/Sources/Baseline/main.swift").read_bytes()).hexdigest(),
                "cargoLockSha256": hashlib.sha256((prototype / "Cargo.lock").read_bytes()).hexdigest(),
                "rust": subprocess.check_output(["rustc", "+1.99.1", "--version"], text=True).strip(),
                "swift": subprocess.check_output(["swift", "--version"], text=True).strip()}
    (out / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(out / "comparison.json")


if __name__ == "__main__":
    main()
