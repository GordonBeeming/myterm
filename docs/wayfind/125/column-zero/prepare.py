"""Build the placement-corrected foundation and apply the cursor-line reflow experiment."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    subprocess.run([sys.executable, str(HERE.parent / 'kitty-placement/prepare.py'),
                    '--baseline-source', str(args.baseline_source.resolve()), '--output', str(out)], check=True)
    subprocess.run(['patch', '--batch', '--forward', '-p1', '-d', str(out / 'native'),
                    '-i', str(HERE / 'reflow.patch')], check=True)
    with (out / 'reflow-build.log').open('w') as log:
        subprocess.run(['cargo', '+1.99.1', 'build', '--offline', '--manifest-path', str(out / 'native/probe/Cargo.toml')],
                       env=dict(os.environ, CARGO_TARGET_DIR=str(out / 'cargo-target')),
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    with (out / 'reflow-swift-build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--package-path', str(out / 'native/swift-probe'),
                        '--scratch-path', str(out / 'native/swift-build')],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copyfile(out / 'native/swift-build/debug/Baseline', out / 'client')
    shutil.copyfile(out / 'cargo-target/debug/wezterm-feasibility', out / 'server')


if __name__ == '__main__':
    main()
