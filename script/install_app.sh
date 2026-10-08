#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 || "$2" != *.app ]]; then
  echo 'usage: install_app.sh <source-app> <destination-app> <callback-scheme>' >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$1"
DESTINATION="$2"
SCHEME="$3"
PARENT="$(dirname "$DESTINATION")"
mkdir -p "$PARENT"
TASK_STAGE="$(mktemp -d "$PARENT/.myterm-install.XXXXXX")"
mv "$TASK_STAGE" "$TASK_STAGE.noindex"
TASK_STAGE="$TASK_STAGE.noindex"
OLD_MOVED=0
NEW_MOVED=0
COMPLETE=0
cleanup() {
  if [[ "$COMPLETE" != 1 && "$NEW_MOVED" == 1 ]]; then
    rm -rf "$DESTINATION"
  fi
  if [[ "$COMPLETE" != 1 && "$OLD_MOVED" == 1 ]]; then
    if ! mv "$TASK_STAGE/previous.disabled" "$DESTINATION"; then
      echo "Could not restore the previous app; it is preserved at $TASK_STAGE/previous.disabled" >&2
      return 1
    fi
    bash "$ROOT_DIR/script/check_callback_routing.sh" "$DESTINATION" "$SCHEME" --repair || true
  fi
  rm -rf "$TASK_STAGE"
}
trap cleanup EXIT
# Stage and verify before stopping the installed app. Replacing avoids stale sealed resources.
ditto "$SOURCE" "$TASK_STAGE/myterm.app"
codesign --verify --deep --strict "$TASK_STAGE/myterm.app"
pkill -x myterm >/dev/null 2>&1 || true
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$TASK_STAGE/previous.disabled"
  OLD_MOVED=1
fi
mv "$TASK_STAGE/myterm.app" "$DESTINATION"
NEW_MOVED=1
codesign --verify --deep --strict "$DESTINATION"
bash "$ROOT_DIR/script/check_callback_routing.sh" "$DESTINATION" "$SCHEME" --repair
COMPLETE=1
