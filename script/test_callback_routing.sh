#!/usr/bin/env bash
set -euo pipefail
# Native handler tests change Launch Services preferences. Run only on disposable CI hosts.
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo "Native callback registration regression runs on disposable CI runners; local registration is untouched."
  exit 0
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Launch Services marks apps in macOS's temporary directories as launch-disabled.
# Use a disposable home directory so lookup follows the same path as a real app copy.
TASK_TEMP="$(mktemp -d "$HOME/.myterm-callback-test.XXXXXX")"
REGISTER_TOOL="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
FIXTURE_PID=""
cleanup() {
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
  "$REGISTER_TOOL" -u "$TASK_TEMP/Old.app" >/dev/null 2>&1 || true
  "$REGISTER_TOOL" -u "$TASK_TEMP/Current.app" >/dev/null 2>&1 || true
  rm -rf "$TASK_TEMP"
}
trap cleanup EXIT
SCHEME="mytermtest$(uuidgen | cut -c 1-8 | tr '[:upper:]' '[:lower:]')"
cat > "$TASK_TEMP/fixture.swift" <<'SWIFT'
import AppKit
import Foundation
if CommandLine.arguments.contains("--hold-for-archive-test") { Thread.sleep(forTimeInterval: 60) }
print("Inert callback test fixture")
SWIFT
swiftc -target "$(uname -m)-apple-macos14.0" "$TASK_TEMP/fixture.swift" -o "$TASK_TEMP/fixture"
python3 - "$TASK_TEMP" "$SCHEME" <<'PY'
from pathlib import Path
import plistlib,shutil,sys
root=Path(sys.argv[1]); scheme=sys.argv[2]
for name in ['Old','Current']:
    app=root/(name+'.app')/'Contents'
    (app/'MacOS').mkdir(parents=True)
    shutil.copy(root/'fixture',app/'MacOS'/'fixture')
    (app/'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':'com.gordonbeeming.'+scheme,
        'CFBundleName':name,'CFBundleExecutable':'fixture','CFBundlePackageType':'APPL',
        'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSMinimumSystemVersion':'14.0',
        'CFBundleURLTypes':[{'CFBundleURLSchemes':[scheme],'CFBundleTypeRole':'Viewer'}]}))
PY
codesign --force --sign - "$TASK_TEMP/Old.app"
codesign --force --sign - "$TASK_TEMP/Current.app"
# These inert fixtures are registered only; no app is launched and production routing is untouched.
bash "$ROOT_DIR/script/check_callback_routing.sh" "$TASK_TEMP/Old.app" "$SCHEME" --repair
if bash "$ROOT_DIR/script/check_callback_routing.sh" "$TASK_TEMP/Current.app" "$SCHEME" > "$TASK_TEMP/wrong-handler.log" 2>&1; then
  echo 'Expected the competing app copy to fail the callback check' >&2
  exit 1
fi
grep -F 'macOS is routing sign-in to another app copy' "$TASK_TEMP/wrong-handler.log"
bash "$ROOT_DIR/script/check_callback_routing.sh" "$TASK_TEMP/Current.app" "$SCHEME" --repair
bash "$ROOT_DIR/script/check_callback_routing.sh" "$TASK_TEMP/Current.app" "$SCHEME"
if [[ -d "$TASK_TEMP/CURRENT.app" ]]; then
  bash "$ROOT_DIR/script/check_callback_routing.sh" "$TASK_TEMP/CURRENT.app" "$SCHEME"
fi
if bash "$ROOT_DIR/script/archive_test_app.sh" "$TASK_TEMP/Current.app" "$TASK_TEMP/Archives"; then
  echo 'Expected the current callback handler to be protected from archival' >&2
  exit 1
fi
test -d "$TASK_TEMP/Current.app"
bash "$ROOT_DIR/script/archive_test_app.sh" "$TASK_TEMP/Old.app" "$TASK_TEMP/Archives"
test ! -d "$TASK_TEMP/Old.app"
test -n "$(ls "$TASK_TEMP/Archives")"
# A differently cased installed-app name must still be protected on APFS.
cp -R "$TASK_TEMP/Current.app" "$TASK_TEMP/MyTerm.app"
if bash "$ROOT_DIR/script/archive_test_app.sh" "$TASK_TEMP/MyTerm.app" "$TASK_TEMP/Archives"; then
  echo 'Expected the installed-app name to be protected regardless of case' >&2
  exit 1
fi
test -d "$TASK_TEMP/MyTerm.app"
# Launch only the inert console executable through a relative path; no GUI is created.
cp -R "$TASK_TEMP/Current.app" "$TASK_TEMP/Running.app"
(cd "$TASK_TEMP"; exec ./Running.app/Contents/MacOS/fixture --hold-for-archive-test) &
FIXTURE_PID=$!
if bash "$ROOT_DIR/script/archive_test_app.sh" "$TASK_TEMP/Running.app" "$TASK_TEMP/Archives"; then
  echo 'Expected a running executable launched by relative path to be protected' >&2
  exit 1
fi
test -d "$TASK_TEMP/Running.app"
kill "$FIXTURE_PID"
wait "$FIXTURE_PID" 2>/dev/null || true
FIXTURE_PID=""
# Installation replaces an old bundle instead of retaining resources removed by the new version.
cp -R "$TASK_TEMP/Current.app" "$TASK_TEMP/Installed.app"
mkdir -p "$TASK_TEMP/Installed.app/Contents/Resources"
touch "$TASK_TEMP/Installed.app/Contents/Resources/obsolete-resource"
bash "$ROOT_DIR/script/install_app.sh" "$TASK_TEMP/Current.app" "$TASK_TEMP/Installed.app" "$SCHEME"
test ! -e "$TASK_TEMP/Installed.app/Contents/Resources/obsolete-resource"
codesign --verify --deep --strict "$TASK_TEMP/Installed.app"
# A signed but malformed replacement must restore the previous bundle after routing fails.
mkdir -p "$TASK_TEMP/Installed.app/Contents/Resources"
touch "$TASK_TEMP/Installed.app/Contents/Resources/rollback-marker"
codesign --force --sign - "$TASK_TEMP/Installed.app"
cp -R "$TASK_TEMP/Current.app" "$TASK_TEMP/NoCallback.app"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$TASK_TEMP/NoCallback.app/Contents/Info.plist"
codesign --force --sign - "$TASK_TEMP/NoCallback.app"
if bash "$ROOT_DIR/script/install_app.sh" "$TASK_TEMP/NoCallback.app" "$TASK_TEMP/Installed.app" "$SCHEME"; then
  echo 'Expected malformed replacement to fail callback verification' >&2
  exit 1
fi
test -f "$TASK_TEMP/Installed.app/Contents/Resources/rollback-marker"
codesign --verify --deep --strict "$TASK_TEMP/Installed.app"
if bash "$ROOT_DIR/script/install_app.sh" "$TASK_TEMP/NoCallback.app" "$TASK_TEMP/FirstInstall.app" "$SCHEME"; then
  echo 'Expected malformed first installation to fail callback verification' >&2
  exit 1
fi
test ! -e "$TASK_TEMP/FirstInstall.app"
"$REGISTER_TOOL" -u "$TASK_TEMP/Installed.app"
echo 'Competing callback handler regression passed'
