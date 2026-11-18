"""Build an isolated window diagnostic against a verified Kitty foundation."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--foundation', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    base, out = args.foundation.resolve(), args.output.resolve()
    manifest = json.loads((base/'graphics-build.json').read_text())
    expected = json.loads((HERE.parent/'kitty-contract/evidence/final/build.json').read_text())
    if manifest['sourceSha256'] != expected['sourceSha256'] or manifest['binarySha256'] != expected['binarySha256']:
        raise RuntimeError('Use the retained verified Kitty foundation')
    for name, value in manifest['sourceSha256'].items():
        if digest(base/name) != value:
            raise RuntimeError('Foundation source changed: '+name)
    for name, value in manifest['binarySha256'].items():
        if digest(base/name) != value:
            raise RuntimeError('Foundation binary changed: '+name)
    out.mkdir(parents=True, exist_ok=False)
    (out/'native').mkdir()
    for name in ('SwiftTerm', 'swift-probe'):
        subprocess.run(['cp', '-cR', str(base/'native'/name), str(out/'native'/name)], check=True)
    shutil.copytree(base/'foundation', out/'foundation')
    shutil.copyfile(base/'server', out/'server')
    (out/'server').chmod(0o755)
    package = out/'native/swift-probe/Package.swift'
    package.write_text(re.sub(r'\.package\(path: "[^"]+"\)', '.package(path: "../SwiftTerm")', package.read_text()))
    subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1', '-d', str(out),
                    '-i', str(HERE/'diagnostic.patch')], check=True)
    command = ['swift', 'build', '--package-path', str(out/'native/swift-probe'),
               '--scratch-path', str(out/'native/raster-build')]
    source = out/'native/swift-probe/Sources/Baseline/main.swift'
    before = digest(source)
    with (out/'build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    if digest(source) != before:
        raise RuntimeError('Diagnostic source changed during build')
    executable = out/'native/raster-build/debug/Baseline'
    shutil.copyfile(executable, out/'raster-client')
    (out/'raster-client').chmod(0o755)
    app = out/'RasterDiagnostic.app'
    (app/'Contents/MacOS').mkdir(parents=True)
    shutil.copyfile(executable, app/'Contents/MacOS/RasterDiagnostic')
    (app/'Contents/MacOS/RasterDiagnostic').chmod(0o755)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'RasterDiagnostic',
        'CFBundleIdentifier': 'com.gordonbeeming.myterm.raster-diagnostic',
        'CFBundleName': 'MyTerm Raster Diagnostic', 'LSMinimumSystemVersion': '14.0',
        'NSPrincipalClass': 'NSApplication',
    }))
    result = {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'foundation': manifest, 'command': command,
              'diagnosticPatchSha256': digest(HERE/'diagnostic.patch'), 'diagnosticSourceSha256': before,
              'binarySha256': {'raster-client': digest(out/'raster-client'), 'server': digest(out/'server')}}
    (out/'diagnostic-build.json').write_text(json.dumps(result, indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
