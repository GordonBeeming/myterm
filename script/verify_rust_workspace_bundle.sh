#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 2 || ( "$2" != com.gordonbeeming.myterm && "$2" != com.gordonbeeming.myterm.rust-rehearsal ) ]]; then
  echo "usage: $0 <myterm.app> <production-or-rehearsal-bundle-id>" >&2
  exit 2
fi

APP_BUNDLE="$1"
SERVER="$APP_BUNDLE/Contents/MacOS/myterm-local-terminal"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
BUNDLE_ID="$2"

[[ -x "$SERVER" ]]
plutil -lint "$INFO_PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == "$BUNDLE_ID" ]]
codesign --verify --deep --strict "$APP_BUNDLE"
for artifact in "$APP_BUNDLE" "$SERVER"; do
  identifier="$BUNDLE_ID"
  if [[ "$artifact" == "$SERVER" ]]; then identifier="$identifier.local-terminal"; fi
  requirement="=anchor apple generic and identifier \"$identifier\" and certificate leaf[subject.OU] = \"89DBN36T4T\""
  requirement="$requirement and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  codesign --verify --test-requirement "$requirement" "$artifact"
  signature="$(codesign -dv "$artifact" 2>&1)"
  if [[ "$signature" != *"flags="*"(runtime)"* ]]; then
    echo "Missing hardened runtime: $artifact" >&2
    exit 1
  fi
done
