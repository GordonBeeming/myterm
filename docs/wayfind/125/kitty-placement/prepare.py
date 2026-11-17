"""Build the retained native checkpoint experiment with the placement correction."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REVISION = 'ab4f866153ff46c03e1e51de72eec8d85d233d51'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--without-correction', action='store_true', help='Build the immutable foundation as a negative control')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True)
    foundation = out / 'foundation'
    foundation.mkdir()
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', REVISION,
                                    'script/wezterm-feasibility'], cwd=ROOT, text=True).splitlines()
    for name in names:
        (foundation / Path(name).name).write_bytes(subprocess.check_output(
            ['git', 'show', f'{REVISION}:{name}'], cwd=ROOT))
    sys.path.insert(0, str(foundation))
    spec = importlib.util.spec_from_file_location('checkpoint', foundation / 'checkpoint.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT = ROOT
    module.prepare(args.baseline_source.resolve(), out / 'native')
    native = out / 'native'
    if not args.without_correction:
        subprocess.run(['patch', '--batch', '--forward', '-p1', '-d', str(native), '-i',
                        str(HERE / 'placement.patch')], check=True)
    # Clone dependency artifacts so the retained baseline executable stays unchanged.
    target = out / 'cargo-target'
    subprocess.run(['cp', '-cR', str(args.baseline_source.resolve().parent / 'probe/target'), str(target)], check=True)
    env = dict(os.environ, CARGO_TARGET_DIR=str(target))
    for command, log in [
        (['cargo', '+1.99.1', 'build', '--offline', '--manifest-path', str(native / 'probe/Cargo.toml')], 'rust-build.log'),
        (['swift', 'build', '--package-path', str(native / 'swift-probe'), '--scratch-path', str(native / 'swift-build')], 'swift-build.log')]:
        with (out / log).open('w') as stream:
            subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, env=env, check=True)
    shutil.copyfile(Path(env['CARGO_TARGET_DIR']) / 'debug/wezterm-feasibility', out / 'server')
    shutil.copyfile(native / 'swift-build/debug/Baseline', out / 'client')
    (out / 'server').chmod(0o755)
    (out / 'client').chmod(0o755)
    print(out)


if __name__ == '__main__':
    main()
