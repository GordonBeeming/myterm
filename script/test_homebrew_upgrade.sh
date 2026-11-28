#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <previous-version> <previous-dmg> <candidate-version> <candidate-dmg>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BREW_REPOSITORY="$(brew --repository)"
TRIAL="$(mktemp -d "${TMPDIR:-/tmp}/myterm-homebrew.XXXXXXXX")"
TRIAL="$(cd "$TRIAL" && pwd -P)"
echo "Homebrew evidence: $TRIAL"

PREFIX="$TRIAL/prefix"
APPS="$TRIAL/apps"
CASK="$PREFIX/Library/Taps/rehearsal/homebrew-local/Casks/myterm.rb"
BREW="$PREFIX/bin/brew"
mkdir -p "$PREFIX/bin" "$PREFIX/Library" "$APPS" "$TRIAL/home" "$TRIAL/temp"
ditto "$BREW_REPOSITORY/bin/brew" "$BREW"
ditto "$BREW_REPOSITORY/Library/Homebrew" "$PREFIX/Library/Homebrew"

# Homebrew must never install into a real prefix or expand the cask's paths in the real home.
TRIAL_HOME="$TRIAL/home"
export HOMEBREW_CACHE="$TRIAL/cache" HOMEBREW_LOGS="$TRIAL/logs" HOMEBREW_TEMP="$TRIAL/temp"
export XDG_CACHE_HOME="$TRIAL/xdg-cache" XDG_CONFIG_HOME="$TRIAL/xdg-config" XDG_DATA_HOME="$TRIAL/xdg-data"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTOREMOVE=1

trial_brew() {
  env HOME="$TRIAL_HOME" "$BREW" "$@"
}
[[ "$(trial_brew --prefix)" == "$PREFIX" ]]

render_local_cask() {
  local version="$1" dmg="$2" variant="$3" checksum
  checksum="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  bash "$ROOT_DIR/script/render_homebrew_cask.sh" "$version" "$checksum" "$CASK"
  python3 - "$CASK" "$dmg" "$variant" <<'PY'
from pathlib import Path
import sys

cask, dmg = map(Path, sys.argv[1:3])
lines = cask.read_text().splitlines(keepends=True)
url_line, = [index for index, line in enumerate(lines) if line.startswith('  url "')]
lines[url_line] = f'  url "{dmg.resolve(strict=True).as_uri()}"\n'
if sys.argv[3] == "published":
    # The previous installed metadata is part of the upgrade surface.
    lines[-1:-1] = [
        '\n  zap trash: [\n',
        '    "~/Library/Application Support/myterm",\n',
        '    "~/Library/Preferences/com.gordonbeeming.myterm.plist",\n',
        '    "~/Library/WebKit/com.gordonbeeming.myterm",\n',
        '  ]\n',
    ]
cask.write_text("".join(lines))
PY
}

render_local_cask "$1" "$2" published
trial_brew trust --tap rehearsal/local
trial_brew install --cask --appdir="$APPS" rehearsal/local/myterm | tee "$TRIAL/install.log"
APP="$APPS/myterm.app"
app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
}
[[ "$(app_version)" == "$1" ]]

STATE="$TRIAL_HOME/Library/Application Support/myterm"
mkdir -p "$STATE/rust-terminal/workspaces" "$TRIAL_HOME/Library/Preferences" "$TRIAL_HOME/Library/WebKit/com.gordonbeeming.myterm"
printf '{"fixture":"workspace configuration"}\n' > "$STATE/workspace-state.json"
printf '{"fixture":"terminal ownership"}\n' > "$STATE/rust-terminal/workspaces/selection.json"
printf 'Fixture preferences\n' > "$TRIAL_HOME/Library/Preferences/com.gordonbeeming.myterm.plist"
printf 'Fixture website data\n' > "$TRIAL_HOME/Library/WebKit/com.gordonbeeming.myterm/fixture"
(
  cd "$TRIAL_HOME"
  shasum -a 256 "Library/Application Support/myterm/workspace-state.json" \
    "Library/Application Support/myterm/rust-terminal/workspaces/selection.json" \
    "Library/Preferences/com.gordonbeeming.myterm.plist" \
    "Library/WebKit/com.gordonbeeming.myterm/fixture"
) > "$TRIAL/state.sha256"

check_state() {
  (cd "$TRIAL_HOME" && shasum -a 256 -c "$TRIAL/state.sha256")
}

render_local_cask "$3" "$4" candidate
trial_brew upgrade --cask --no-quit --no-ask rehearsal/local/myterm | tee "$TRIAL/upgrade.log"
[[ "$(app_version)" == "$3" ]]
bash "$ROOT_DIR/script/verify_rust_workspace_bundle.sh" "$APP" com.gordonbeeming.myterm
check_state

# Exercise zap immediately after upgrading the installed metadata from the previous cask.
trial_brew uninstall --cask --zap rehearsal/local/myterm | tee "$TRIAL/zap.log"
[[ ! -e "$APP" ]]
check_state

trial_brew install --cask --appdir="$APPS" rehearsal/local/myterm | tee "$TRIAL/reinstall.log"
[[ "$(app_version)" == "$3" ]]
check_state

trial_brew uninstall --cask rehearsal/local/myterm | tee "$TRIAL/uninstall.log"
[[ ! -e "$APP" ]]
check_state
echo "Verified Homebrew upgrade, installed signatures, and state retention after uninstall."
