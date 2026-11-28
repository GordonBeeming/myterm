#!/usr/bin/env bash
set -euo pipefail

CHANNEL="development"
MODE="run"
LOCAL_RUST_TERMINAL=0
RUST_WORKSPACES=0
RUST_RELEASE_REHEARSAL=0

usage() {
  echo "usage: $0 [--prod|--local-rust-terminal|--local-rust-workspaces|--rust-release-rehearsal] [--bundle|--debug|--logs|--telemetry|--verify|--print-plan]" >&2
}

while (($#)); do
  case "$1" in
    --prod)
      CHANNEL="production"
      ;;
    --local-rust-terminal)
      LOCAL_RUST_TERMINAL=1
      ;;
    --local-rust-workspaces)
      LOCAL_RUST_TERMINAL=1
      RUST_WORKSPACES=1
      ;;
    --rust-release-rehearsal)
      RUST_RELEASE_REHEARSAL=1
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
SHIP_RUST_WORKSPACES="${MYTERM_SHIP_RUST_WORKSPACES:-0}"
RELEASE_CHANNEL="${MYTERM_RELEASE_CHANNEL:-stable}"
ENTITLEMENTS_PATH="${MYTERM_ENTITLEMENTS_PATH:-$ROOT_DIR/Packaging/MyTerm.entitlements}"

if [[ "$SHIP_RUST_WORKSPACES" != "0" && "$SHIP_RUST_WORKSPACES" != "1" ]]; then
  echo "MYTERM_SHIP_RUST_WORKSPACES must be 0 or 1" >&2
  exit 2
fi
if [[ "$SHIP_RUST_WORKSPACES" == "1" ]]; then
  if [[ "$CHANNEL" != "production" || "$DISTRIBUTION" != "1" || "$RUST_RELEASE_REHEARSAL" == "1" || "$LOCAL_RUST_TERMINAL" == "1"
        || ( "$MODE" != "--bundle" && "$MODE" != "--print-plan" ) ]]; then
    echo "MYTERM_SHIP_RUST_WORKSPACES requires --prod, MYTERM_DISTRIBUTION=1 and --bundle or --print-plan." >&2
    exit 2
  fi
  LOCAL_RUST_TERMINAL=1
  RUST_WORKSPACES=1
fi

if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  if [[ "$CHANNEL" != "development" || "$LOCAL_RUST_TERMINAL" == "1" || "$DISTRIBUTION" != "0" ]]; then
    echo "The Rust release rehearsal is a standalone, local build mode." >&2
    exit 2
  fi
  CHANNEL="production"
  LOCAL_RUST_TERMINAL=1
  RUST_WORKSPACES=1
fi

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

if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  BUNDLE_ID="com.gordonbeeming.myterm.rust-rehearsal"
  DIST_DIR="$DIST_DIR/rust-release-rehearsal"
  BUILD_ARGS+=(--scratch-path "$ROOT_DIR/.build/rust-release-rehearsal" -Xswiftc -DMYTERM_RUST_RELEASE_REHEARSAL)
elif [[ "$SHIP_RUST_WORKSPACES" == "1" ]]; then
  BUILD_ARGS+=(--scratch-path "$ROOT_DIR/.build/rust-production-workspaces")
elif [[ "$RUST_WORKSPACES" == "1" ]]; then
  DIST_DIR="$DIST_DIR/rust-workspaces"
fi
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APPLICATION_SUPPORT_DIRECTORY="${MYTERM_APPLICATION_SUPPORT_DIRECTORY:-$HOME/Library/Application Support}"
if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  APPLICATION_SUPPORT_DIRECTORY="${MYTERM_APPLICATION_SUPPORT_DIRECTORY:-}"
elif [[ "$RUST_WORKSPACES" == "1" && "$CHANNEL" == "development" ]]; then
  APPLICATION_SUPPORT_DIRECTORY="$APPLICATION_SUPPORT_DIRECTORY/MyTerm Rust Workspaces Development"
fi
if [[ -n "$APPLICATION_SUPPORT_DIRECTORY" ]]; then
  WORKSPACE_STATE_PATH="$APPLICATION_SUPPORT_DIRECTORY/$APP_NAME/workspace-state.json"
else
  WORKSPACE_STATE_PATH="isolated-support-directory-required/$APP_NAME/workspace-state.json"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "MYTERM_VERSION must use major.minor or major.minor.patch format" >&2
  exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "MYTERM_BUILD must be a positive integer" >&2
  exit 2
fi

if [[ "$RELEASE_CHANNEL" != "stable" && "$RELEASE_CHANNEL" != "beta" ]]; then
  echo "MYTERM_RELEASE_CHANNEL must be stable or beta" >&2
  exit 2
fi

if [[ "$DISTRIBUTION" != "0" && "$DISTRIBUTION" != "1" ]]; then
  echo "MYTERM_DISTRIBUTION must be 0 or 1" >&2
  exit 2
fi

if [[ "$LOCAL_RUST_TERMINAL" == "1" && "$RUST_RELEASE_REHEARSAL" == "0" && "$SHIP_RUST_WORKSPACES" == "0" && ( "$CHANNEL" != "development" || "$DISTRIBUTION" != "0" ) ]]; then
  echo "The local Rust terminal is available only in development bundles." >&2
  exit 2
fi
if [[ "$LOCAL_RUST_TERMINAL" == "1" ]]; then
  BUILD_ARGS+=(-Xswiftc -DMYTERM_LOCAL_RUST_TERMINAL)
fi

if [[ "$RUST_WORKSPACES" == "1" ]]; then
  BUILD_ARGS+=(-Xswiftc -DMYTERM_RUST_WORKSPACES -Xswiftc -DMYTERM_WEZTERM_CHECKPOINT)
fi

if [[ "$MODE" == "--print-plan" ]]; then
  printf 'channel=%s\n' "$CHANNEL"
  printf 'app_name=%s\n' "$APP_NAME"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'app_bundle=%s\n' "$APP_BUNDLE"
  printf 'workspace_state_path=%s\n' "$WORKSPACE_STATE_PATH"
  printf 'instance_policy=focus-existing\n'
  printf 'build_configuration=%s\n' "$BUILD_CONFIGURATION"
  if [[ "$LOCAL_RUST_TERMINAL" == "1" ]]; then printf 'local_rust_terminal=1\n'; fi
  if [[ "$RUST_WORKSPACES" == "1" ]]; then printf 'local_rust_workspaces=1\n'; fi
  if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then printf 'rust_release_rehearsal=1\n'; fi
  if [[ "$SHIP_RUST_WORKSPACES" == "1" ]]; then printf 'ship_rust_workspaces=1\n'; fi
  if [[ "$LOCAL_RUST_TERMINAL" == "1" ]]; then printf 'rust_server=%s\n' "$APP_MACOS/myterm-local-terminal"; fi
  exit 0
fi

if [[ "$LOCAL_RUST_TERMINAL" == "1" && ! -f "$ROOT_DIR/Services/terminal-state/dependencies/prepare.py" ]]; then
  echo "The Rust terminal build requires the pinned terminal-state engine preparation script." >&2
  exit 2
fi
if [[ "$RUST_WORKSPACES" == "1" && ! -f "$ROOT_DIR/Vendor/SwiftTerm/Sources/SwiftTerm/CheckpointBridge.swift" ]]; then
  echo "Rust workspaces require the native SwiftTerm checkpoint importer." >&2
  exit 2
fi

if [[ "$RUST_RELEASE_REHEARSAL" == "1" && "$MODE" != "--bundle" ]]; then
  if [[ "$MODE" != "run" ]]; then
    echo "Use --bundle for headless verification or omit the mode to launch the rehearsal." >&2
    exit 2
  fi
  if [[ "$APPLICATION_SUPPORT_DIRECTORY" != /* || ! -d "$APPLICATION_SUPPORT_DIRECTORY" ]]; then
    echo "Set MYTERM_APPLICATION_SUPPORT_DIRECTORY to an existing, private copy's absolute parent directory." >&2
    exit 2
  fi
fi

source "$ROOT_DIR/script/select_signing_identity.sh"
if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  SIGNING_IDENTITY="$(myterm_select_signing_identity 1)"
else
  SIGNING_IDENTITY="$(myterm_select_signing_identity "$DISTRIBUTION")"
fi
if [[ "$LOCAL_RUST_TERMINAL" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "The local Rust terminal requires an Apple-issued signing identity." >&2
  exit 2
fi

cd "$ROOT_DIR"
swift build --product MyTerm "${BUILD_ARGS[@]}"
swift build --product MyTermSessionHost "${BUILD_ARGS[@]}"
swift build --product MyTermUpdateAgent "${BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build --show-bin-path "${BUILD_ARGS[@]}")/MyTerm"
RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/SwiftTerm_SwiftTerm.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "SwiftTerm's compiled resource bundle is missing: $RESOURCE_BUNDLE" >&2
  exit 1
fi
if [[ "$LOCAL_RUST_TERMINAL" == "1" ]]; then
  RUST_TARGET_DIR="$ROOT_DIR/.build/local-rust-terminal"
  RUST_BUILD_ARGS=()
  if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
    RUST_TARGET_DIR="$ROOT_DIR/.build/rust-release-rehearsal-server"
    RUST_BUILD_ARGS+=(--features release-rehearsal)
  elif [[ "$SHIP_RUST_WORKSPACES" == "1" ]]; then
    RUST_TARGET_DIR="$ROOT_DIR/.build/rust-production-workspaces-server"
    RUST_BUILD_ARGS+=(--features production)
  fi
  python3 "$ROOT_DIR/Services/terminal-state/dependencies/prepare.py"
  MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION" cargo +1.99.1 build --locked --release \
    --manifest-path "$ROOT_DIR/Services/local-terminal/Cargo.toml" --target-dir "$RUST_TARGET_DIR" \
    ${RUST_BUILD_ARGS[@]+"${RUST_BUILD_ARGS[@]}"}
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$(dirname "$BUILD_BINARY")/MyTermSessionHost" "$APP_MACOS/MyTermSessionHost"
cp "$(dirname "$BUILD_BINARY")/MyTermUpdateAgent" "$APP_MACOS/MyTermUpdateAgent"
cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
cp "$ROOT_DIR/Resources/MyTerm.icns" "$APP_RESOURCES/MyTerm.icns"
cp "$ROOT_DIR/Resources/myterm-browser" "$APP_RESOURCES/myterm-browser"
cp "$ROOT_DIR/Resources/open" "$APP_RESOURCES/open"
cp "$ROOT_DIR/Resources/myterm-bash-env" "$APP_RESOURCES/myterm-bash-env"
cp "$ROOT_DIR/Resources/myterm-agent-hook" "$APP_RESOURCES/myterm-agent-hook"
cp "$ROOT_DIR/Resources/myterm-agent-normalize.js" "$APP_RESOURCES/myterm-agent-normalize.js"
cp "$ROOT_DIR/Resources/myterm-antigravity-status" "$APP_RESOURCES/myterm-antigravity-status"
cp "$ROOT_DIR/Resources/myterm-bash-startup" "$APP_RESOURCES/myterm-bash-startup"
cp "$ROOT_DIR/Resources/myterm-fish-startup.fish" "$APP_RESOURCES/myterm-fish-startup.fish"
for launcher in codex codex-statusline myterm-codex; do
  cp "$ROOT_DIR/Resources/$launcher" "$APP_RESOURCES/$launcher"
  chmod +x "$APP_RESOURCES/$launcher"
done
cp -R "$ROOT_DIR/Resources/Fonts" "$APP_RESOURCES/Fonts"
cp -R "$ROOT_DIR/Resources/zsh" "$APP_RESOURCES/"
chmod +x "$APP_BINARY"
chmod +x "$APP_RESOURCES/myterm-browser"
chmod +x "$APP_RESOURCES/open"

cp "$ROOT_DIR/Packaging/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :MyTermReleaseChannel string $RELEASE_CHANNEL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :MyTermChannelConfigurationVersion integer 1' "$INFO_PLIST"
if [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  bash "$ROOT_DIR/script/configure_url_handlers.sh" development "$BUNDLE_ID" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 myterm-rust-rehearsal' "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c 'Set :UTExportedTypeDeclarations:0:UTTypeIdentifier com.gordonbeeming.myterm.rust-rehearsal.sidebar-item' "$INFO_PLIST"
else
  bash "$ROOT_DIR/script/configure_url_handlers.sh" "$CHANNEL" "$BUNDLE_ID" "$INFO_PLIST"
fi
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_SYSTEM_VERSION" "$INFO_PLIST"


CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$DISTRIBUTION" == "1" ]]; then
  CODESIGN_ARGS+=(--options runtime --timestamp)
elif [[ "$LOCAL_RUST_TERMINAL" == "1" ]]; then
  CODESIGN_ARGS+=(--options runtime)
fi
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
  CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
HOST_CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID.session-host")
if [[ "$DISTRIBUTION" == "1" ]]; then
  HOST_CODESIGN_ARGS+=(--options runtime --timestamp)
elif [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  HOST_CODESIGN_ARGS+=(--options runtime)
fi
codesign "${HOST_CODESIGN_ARGS[@]}" "$APP_MACOS/MyTermSessionHost"
UPDATE_CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID.update-agent")
if [[ "$DISTRIBUTION" == "1" ]]; then
  UPDATE_CODESIGN_ARGS+=(--options runtime --timestamp)
elif [[ "$RUST_RELEASE_REHEARSAL" == "1" ]]; then
  UPDATE_CODESIGN_ARGS+=(--options runtime)
fi
codesign "${UPDATE_CODESIGN_ARGS[@]}" "$APP_MACOS/MyTermUpdateAgent"
if [[ "$LOCAL_RUST_TERMINAL" == "1" ]]; then
  cp "$RUST_TARGET_DIR/release/myterm-local-terminal" "$APP_MACOS/myterm-local-terminal"
  RUST_CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID.local-terminal" --options runtime)
  if [[ "$DISTRIBUTION" == "1" ]]; then RUST_CODESIGN_ARGS+=(--timestamp); fi
  codesign "${RUST_CODESIGN_ARGS[@]}" "$APP_MACOS/myterm-local-terminal"
fi
codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"

if [[ "$RUST_RELEASE_REHEARSAL" == "1" || "$SHIP_RUST_WORKSPACES" == "1" ]]; then
  bash "$ROOT_DIR/script/verify_rust_workspace_bundle.sh" "$APP_BUNDLE" "$BUNDLE_ID"
fi

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
