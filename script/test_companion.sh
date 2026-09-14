#!/bin/bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_directory=$(cd -- "$script_directory/.." && pwd)
cd "$repo_directory"
bash script/verify_companion_toolchain.sh 27.0

device_family="${COMPANION_DEVICE_FAMILY:-iPhone}"
case "$device_family" in
  iPhone|iPad) ;;
  *) echo "COMPANION_DEVICE_FAMILY must be iPhone or iPad" >&2; exit 2 ;;
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
  device_description=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
family = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if ".iOS-27-" not in runtime:
        continue
    candidates = [item for item in devices[runtime]
                  if item.get("isAvailable") and item["name"].startswith(family)
                  and item.get("deviceTypeIdentifier")]
    if candidates:
        chosen = sorted(candidates, key=lambda item: item["name"])[0]
        print(runtime + "\t" + chosen["deviceTypeIdentifier"])
        sys.exit(0)
print(f"No available iOS 27 {family} runtime/device type.", file=sys.stderr)
sys.exit(1)
' "$device_family")
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
