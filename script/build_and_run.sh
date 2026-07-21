#!/usr/bin/env bash
set -euo pipefail

CHANNEL="development"
MODE="run"

usage() {
  echo "usage: $0 [--prod] [--debug|--logs|--telemetry|--verify]" >&2
}

while (($#)); do
  case "$1" in
    --prod)
      CHANNEL="production"
      ;;
    --debug|--logs|--telemetry|--verify)
      if [[ "$MODE" != "run" ]]; then
        usage
        exit 2
      fi
      MODE="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
MIN_SYSTEM_VERSION="14.0"

if [[ "$CHANNEL" == "production" ]]; then
  APP_NAME="myterm"
  BUNDLE_ID="com.gordonbeeming.myterm"
  BUILD_ARGS=(--configuration release -Xswiftc -DMYTERM_PRODUCTION)
else
  APP_NAME="myterm-dev"
  BUNDLE_ID="com.gordonbeeming.myterm.dev"
  BUILD_ARGS=(--configuration debug)
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --product MyTerm "${BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build --show-bin-path "${BUILD_ARGS[@]}")/MyTerm"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/MyTerm.icns" "$APP_RESOURCES/MyTerm.icns"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>MyTerm</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.web</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>http</string>
        <string>https</string>
      </array>
    </dict>
  </array>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  local open_args=(-n)
  if [[ -n "${MYTERM_APPLICATION_SUPPORT_DIRECTORY:-}" ]]; then
    open_args+=(--env "MYTERM_APPLICATION_SUPPORT_DIRECTORY=$MYTERM_APPLICATION_SUPPORT_DIRECTORY")
  fi
  if [[ -n "${MYTERM_USER_DEFAULTS_SUITE:-}" ]]; then
    open_args+=(--env "MYTERM_USER_DEFAULTS_SUITE=$MYTERM_USER_DEFAULTS_SUITE")
  fi
  /usr/bin/open "${open_args[@]}" "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
