"""Build the bounded Kitty correction from its verified checkpoint foundation."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
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
    subprocess.run([sys.executable, str(HERE.parent/'column-zero/prepare.py'),
                    '--baseline-source', str(args.baseline_source.resolve()),
                    '--output', str(out)], check=True)
    expected = json.loads((HERE/'base-hashes.json').read_text())
    for name, value in expected.items():
        if digest(out/name) != value:
            raise RuntimeError(f'Checkpoint foundation differs: {name}')
    subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1', '-d', str(out),
                    '-i', str(HERE/'graphics.patch')], check=True)
    sources = {name: digest(out/name) for name in expected}
    environment = dict(os.environ, CARGO_TARGET_DIR=str(out/'cargo-target'))
    commands = [
        (['cargo', '+1.99.1', 'build', '--offline', '--manifest-path',
          str(out/'native/probe/Cargo.toml')], 'graphics-rust-build.log'),
        (['swift', 'build', '--package-path', str(out/'native/swift-probe'),
          '--scratch-path', str(out/'native/swift-build')], 'graphics-swift-build.log'),
    ]
    for command, log in commands:
        with (out/log).open('w') as stream:
            subprocess.run(command, env=environment, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
    if sources != {name: digest(out/name) for name in expected}:
        raise RuntimeError('Sources changed during compilation')
    shutil.copyfile(out/'cargo-target/debug/wezterm-feasibility', out/'server')
    shutil.copyfile(out/'native/swift-build/debug/Baseline', out/'client')
    manifest = {
        'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'platform': platform.platform(),
        'sourceSha256': sources,
        'patchSha256': digest(HERE/'graphics.patch'),
        'binarySha256': {name: digest(out/name) for name in ('server', 'client')},
        'sourcesUnchangedDuringBuild': True,
    }
    (out/'graphics-build.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
