#!/usr/bin/env bash
set -euo pipefail

CHANNEL="development"
MODE="run"

usage() {
  echo "usage: $0 [--prod] [--bundle|--debug|--logs|--telemetry|--verify|--print-plan]" >&2
}

while (($#)); do
  case "$1" in
    --prod)
      CHANNEL="production"
      ;;
    --bundle|--debug|--logs|--telemetry|--verify|--print-plan)
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
VERSION="${MYTERM_VERSION:-0.1.0}"
BUILD_NUMBER="${MYTERM_BUILD:-1}"
DISTRIBUTION="${MYTERM_DISTRIBUTION:-0}"
ENTITLEMENTS_PATH="${MYTERM_ENTITLEMENTS_PATH:-$ROOT_DIR/Packaging/MyTerm.entitlements}"

if [[ "$CHANNEL" == "production" ]]; then
  APP_NAME="myterm"
  BUNDLE_ID="com.gordonbeeming.myterm"
  BUILD_CONFIGURATION="release"
  BUILD_ARGS=(--configuration release -Xswiftc -DMYTERM_PRODUCTION)
else
  APP_NAME="myterm-dev"
  BUNDLE_ID="com.gordonbeeming.myterm.dev"
  BUILD_CONFIGURATION="debug"
  BUILD_ARGS=(--configuration debug)
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APPLICATION_SUPPORT_DIRECTORY="${MYTERM_APPLICATION_SUPPORT_DIRECTORY:-$HOME/Library/Application Support}"
WORKSPACE_STATE_PATH="$APPLICATION_SUPPORT_DIRECTORY/$APP_NAME/workspace-state.json"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "MYTERM_VERSION must use major.minor or major.minor.patch format" >&2
  exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "MYTERM_BUILD must be a positive integer" >&2
  exit 2
fi

if [[ "$DISTRIBUTION" != "0" && "$DISTRIBUTION" != "1" ]]; then
  echo "MYTERM_DISTRIBUTION must be 0 or 1" >&2
  exit 2
fi

if [[ "$MODE" == "--print-plan" ]]; then
  printf 'channel=%s\n' "$CHANNEL"
  printf 'app_name=%s\n' "$APP_NAME"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'app_bundle=%s\n' "$APP_BUNDLE"
  printf 'workspace_state_path=%s\n' "$WORKSPACE_STATE_PATH"
  printf 'process_kill_target=%s\n' "$APP_NAME"
  printf 'build_configuration=%s\n' "$BUILD_CONFIGURATION"
  exit 0
fi

if [[ "$MODE" != "--bundle" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build --product MyTerm "${BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build --show-bin-path "${BUILD_ARGS[@]}")/MyTerm"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/MyTerm.icns" "$APP_RESOURCES/MyTerm.icns"
cp "$ROOT_DIR/Resources/myterm-browser" "$APP_RESOURCES/myterm-browser"
chmod +x "$APP_BINARY"
chmod +x "$APP_RESOURCES/myterm-browser"

cp "$ROOT_DIR/Packaging/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID.web" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLName $BUNDLE_ID.terminal" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_SYSTEM_VERSION" "$INFO_PLIST"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_PATTERN="Apple Development"
  if [[ "$DISTRIBUTION" == "1" ]]; then
    SIGNING_PATTERN="Developer ID Application"
  fi
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' -v pattern="$SIGNING_PATTERN" '$0 ~ pattern {print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

if [[ "$DISTRIBUTION" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Distribution bundling requires a Developer ID Application identity" >&2
  exit 1
fi

CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$DISTRIBUTION" == "1" ]]; then
  CODESIGN_ARGS+=(--options runtime --timestamp)
fi
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
  CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"

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
  --bundle)
    ;;
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
