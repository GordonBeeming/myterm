#!/bin/bash
set -euo pipefail

minimum_sdk="${1:-26.0}"
if [[ ! "$minimum_sdk" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 [minimum-ios-sdk, e.g. 26.0]" >&2
  exit 2
fi

xcodebuild -version
installed_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
python3 - "$minimum_sdk" "$installed_sdk" <<'PY'
import sys

def version(value):
    parts = value.split('.')
    if not all(part.isdecimal() for part in parts):
        raise ValueError(f'Unexpected SDK version: {value}')
    return tuple(int(part) for part in parts)

required, installed = sys.argv[1:]
if version(installed) < version(required):
    print(
        f'Companion validation requires the iOS {required} SDK; '
        f'the selected Xcode provides {installed}. '
        'Select a supported Xcode with DEVELOPER_DIR before building.',
        file=sys.stderr,
    )
    sys.exit(1)
print(f'Companion SDK verified: iOS {installed} (minimum {required}).')
PY
