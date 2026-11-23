#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
device_type="${1:-com.apple.CoreSimulator.SimDeviceType.iPhone-11}"
runtime="${2:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
run_dir="$(mktemp -d /private/tmp/myterm-browser-trusted.XXXXXX)"
printf 'Run directory: %s\n' "$run_dir" >&2
cd "$run_dir"
export GOCACHE="$run_dir/go-cache"
export GOTOOLCHAIN=local
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"
bundle=com.gordonbeeming.myterm.wayfind.proxyprobe

go build -o relay "$source_dir/relay.go"
mkdir Probe.app
cp "$source_dir/SimulatorInfo.plist" Probe.app/Info.plist
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 \
    -target arm64-apple-ios26.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$source_dir/probe.swift" -o Probe.app/Probe \
    -framework UIKit -framework WebKit -framework Network -framework Security
codesign --force --sign - Probe.app

device_id=""
relay_pid=""
cleanup() {
    if [[ -n "$device_id" ]]; then
        xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "$relay_pid" ]]; then kill "$relay_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
./relay --issue-root > relay.port 2> relay.log &
relay_pid=$!
for _ in {1..50}; do
    if [[ -s relay.port ]]; then break; fi
    if ! kill -0 "$relay_pid" 2>/dev/null; then cat relay.log >&2; exit 1; fi
    sleep 0.1
done
relay_port="$(cat relay.port)"
[[ -n "$relay_port" ]] || { cat relay.log >&2; exit 1; }

device_id="$(xcrun simctl create "myterm-trusted-proxy-$$" "$device_type" "$runtime")"
xcrun simctl bootstatus "$device_id" -b > boot.log 2>&1
xcrun simctl keychain "$device_id" add-root-cert "$run_dir/root.der"
xcrun simctl install "$device_id" "$run_dir/Probe.app"
app_data="$(xcrun simctl get_app_container "$device_id" "$bundle" data)"
result="$app_data/Documents/routing-result.json"

launch_probe() {
    local mode="$1"
    SIMCTL_CHILD_MYTERM_PROBE_PORT="$relay_port" SIMCTL_CHILD_MYTERM_PROBE_STATE="$mode" \
        xcrun simctl launch --terminate-running-process "$device_id" "$bundle" >&2
    for _ in {1..100}; do
        if [[ -s "$result" ]] && jq -e 'has("probeError")' "$result" >/dev/null; then
            cat "$result" >&2
            return 1
        fi
        if [[ -s "$result" ]] && jq -e --arg mode "$mode" '.relayState == $mode' "$result" >/dev/null; then
            cp "$result" "$mode.json"
            return
        fi
        sleep 0.5
    done
    xcrun simctl spawn "$device_id" log show --last 1m --predicate 'process == "Probe"' \
        --style compact > probe-failure.log 2>/dev/null || true
    printf 'Timed out waiting for the %s result. See %s.\n' "$mode" "$run_dir/probe-failure.log" >&2
    return 1
}

launch_probe running
kill "$relay_pid"
wait "$relay_pid" 2>/dev/null || true
relay_pid=""
launch_probe stopped

jq -s . running.json stopped.json
cat relay.log >&2
