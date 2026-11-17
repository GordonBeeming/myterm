"""Build the retained native checkpoint experiment with empty-buffer resizing corrected."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    subprocess.run([sys.executable, str(HERE.parent/'kitty-contract/prepare.py'),
                    '--baseline-source', str(args.baseline_source.resolve()),
                    '--output', str(out)], check=True)
    source = out/'native/SwiftTerm/Sources/SwiftTerm/Buffer.swift'
    before = digest(source)
    names = list(json.loads((HERE.parent/'kitty-contract/base-hashes.json').read_text()))
    names.append('native/SwiftTerm/Sources/SwiftTerm/Buffer.swift')
    baseline_sources = {name: digest(out/name) for name in names}
    (out/'graphics-build.json').rename(out/'foundation-graphics-build.json')
    subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1', '-d', str(out),
                    '-i', str(HERE/'resize.patch')], check=True)
    after = digest(source)
    sources = {name: digest(out/name) for name in names}
    for command, name in [
        (['cargo', '+1.99.1', 'build', '--offline', '--manifest-path',
          str(out/'native/probe/Cargo.toml')], 'alternate-rust-build.log'),
        (['swift', 'build', '--package-path', str(out/'native/swift-probe'),
          '--scratch-path', str(out/'native/swift-build')], 'alternate-swift-build.log')]:
        with (out/name).open('w') as log:
            subprocess.run(command, env=dict(os.environ, CARGO_TARGET_DIR=str(out/'cargo-target')),
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    if sources != {name: digest(out/name) for name in names}:
        raise RuntimeError('Sources changed during compilation')
    shutil.copyfile(out/'native/swift-build/debug/Baseline', out/'client')
    shutil.copyfile(out/'cargo-target/debug/wezterm-feasibility', out/'server')
    (out/'alternate-build.json').write_text(json.dumps({
        'timestampUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'bufferBeforeSha256': before, 'bufferAfterSha256': after,
        'patchSha256': digest(HERE/'resize.patch'),
        'sourceSha256': sources,
        'baselineSourceSha256': baseline_sources,
        'foundationManifest': 'foundation-graphics-build.json',
        'foundationManifestPurpose': 'Intermediate stage; its executable hashes precede this correction',
        'binarySha256': {name: digest(out/name) for name in ('client', 'server')},
        'scope': 'bounded native macOS experiment; production sources unchanged',
    }, indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
