#!/bin/bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_directory=$(cd -- "$script_directory/.." && pwd)
cd "$repo_directory"
bash script/verify_companion_toolchain.sh 27.1

device_family="${COMPANION_DEVICE_FAMILY:-iPhone}"
case "$device_family" in
  iPhone|iPad|iPhoneDuo) ;;
  *) echo "COMPANION_DEVICE_FAMILY must be iPhone, iPad, or iPhoneDuo" >&2; exit 2 ;;
esac

device_id="${COMPANION_SIMULATOR_UDID:-}"
owned_device=""
cleanup() {
  if [[ -n "$owned_device" && "${COMPANION_KEEP_SIMULATOR:-0}" != "1" ]]; then
    xcrun simctl shutdown "$owned_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$owned_device" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -z "$device_id" ]]; then
  simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
  device_description=$(xcrun simctl list --json | python3 script/select_companion_simulator.py "$device_family" "$simulator_sdk")
  IFS=$'\t' read -r runtime_id device_type <<< "$device_description"
  owned_device=$(xcrun simctl create "myterm-companion-test-${device_family}-$$" "$device_type" "$runtime_id")
  device_id="$owned_device"
fi

mkdir -p dist
result_path="dist/companion-${device_family}.xcresult"
if [[ -e "$result_path" ]]; then
  echo "Test results already exist at $result_path; preserve or move them before rerunning." >&2
  exit 1
fi

xcodebuild test \
  -project Companion/MyTermCompanion.xcodeproj \
  -scheme MyTermCompanion \
  -destination "platform=iOS Simulator,id=$device_id" \
  -resultBundlePath "$result_path" \
  CODE_SIGNING_ALLOWED=NO
