#!/bin/bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_directory=$(cd -- "$script_directory/.." && pwd)
cd "$repo_directory"
bash script/verify_companion_toolchain.sh 27.1

device_family="${COMPANION_DEVICE_FAMILY:-iPhone}"
case "$device_family" in
  iPhone) product_family="iPhone"; required_device_type="" ;;
  iPad) product_family="iPad"; required_device_type="" ;;
  iPhoneDuo) product_family="iPhone"; required_device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-Duo" ;;
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
  device_description=$(xcrun simctl list --json | python3 -c '
import json, sys
family = sys.argv[1]
product_family = sys.argv[2]
sdk_version = sys.argv[3]
required_device_type = sys.argv[4]
sdk_major = int(sdk_version.split(".")[0])
inventory = json.load(sys.stdin)
runtimes = sorted(inventory["runtimes"], key=lambda item: item["version"], reverse=True)
for runtime in runtimes:
    if not runtime.get("isAvailable") or runtime.get("platform") != "iOS":
        continue
    if int(runtime["version"].split(".")[0]) != sdk_major:
        continue
    if family == "iPhoneDuo" and runtime["version"] != sdk_version:
        continue
    candidates = [item for item in runtime.get("supportedDeviceTypes", [])
                  if item.get("productFamily") == product_family and item.get("identifier")]
    if family == "iPhone":
        candidates = [item for item in candidates if item["name"] != "iPhone Duo"]
    if required_device_type:
        candidates = [item for item in candidates
                      if item["identifier"] == required_device_type]
    if candidates:
        chosen = sorted(candidates, key=lambda item: item["name"])[0]
        print(runtime["identifier"] + "\t" + chosen["identifier"])
        sys.exit(0)
print(f"No available iOS {sdk_major} {family} runtime/device type.", file=sys.stderr)
sys.exit(1)
' "$device_family" "$product_family" "$simulator_sdk" "$required_device_type")
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
