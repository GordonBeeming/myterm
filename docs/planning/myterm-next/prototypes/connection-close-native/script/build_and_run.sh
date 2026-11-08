#!/bin/bash
set -euo pipefail

prototype_root="$(cd "$(dirname "$0")/.." && pwd)"
prototype_scratch="${MYTERM_PROTOTYPE_SCRATCH:-/private/tmp/myterm-157-native-build}"
prototype_bundle="$prototype_scratch/ConnectionClosePrototype.app"

swift build --package-path "$prototype_root" --scratch-path "$prototype_scratch"
mkdir -p "$prototype_bundle/Contents/MacOS"
cp "$prototype_scratch/debug/ConnectionClosePrototype" "$prototype_bundle/Contents/MacOS/ConnectionClosePrototype"
python3 - "$prototype_bundle/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundlePackageType': 'APPL',
    'CFBundleExecutable': 'ConnectionClosePrototype',
    'CFBundleIdentifier': 'com.gordonbeeming.myterm.connection-close-prototype.mac',
    'CFBundleName': 'MyTerm Connection Prototype',
    'LSMinimumSystemVersion': '14.0',
    'NSPrincipalClass': 'NSApplication',
}))
PY

if [[ "${1:-}" != "--bundle" ]]; then
    /usr/bin/open -n "$prototype_bundle"
fi
