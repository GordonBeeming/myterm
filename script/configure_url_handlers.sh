#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 || ( "$1" != production && "$1" != development ) ]]; then
  echo 'usage: configure_url_handlers.sh <production|development> <bundle-id> <info-plist>' >&2
  exit 2
fi
CHANNEL="$1"
BUNDLE_ID="$2"
INFO_PLIST="$3"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID.web" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLName $BUNDLE_ID.terminal" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:2:CFBundleURLName $BUNDLE_ID.workspace" "$INFO_PLIST"
if [[ "$CHANNEL" == development ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:2:CFBundleURLSchemes:0 myterm-dev' "$INFO_PLIST"
  # Development/test builds must not claim production callbacks, browser or SSH links.
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes:0' "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes:0' "$INFO_PLIST"
fi
