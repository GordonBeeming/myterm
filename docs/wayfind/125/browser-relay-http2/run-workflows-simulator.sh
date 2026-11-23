#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
device_type="${1:-com.apple.CoreSimulator.SimDeviceType.iPhone-11}"
runtime="${2:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
run_dir="$(mktemp -d /private/tmp/myterm-workflows.XXXXXX)"
printf 'Run directory: %s\n' "$run_dir" >&2
cd "$run_dir"
export GOCACHE="$run_dir/go-cache"
export GOTOOLCHAIN=local
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"
bundle=com.gordonbeeming.myterm.wayfind.proxyprobe

go -C "$source_dir" build -mod=readonly -o "$run_dir/relay" relay.go
go -C "$source_dir" build -mod=readonly -o "$run_dir/origin-fixture" ./origin

device_id=""
pids=()
cleanup() {
    if [[ -n "$device_id" ]]; then
        xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
    fi
    for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

await_port() {
    local path="$1" pid="$2"
    for _ in {1..60}; do
        if [[ -s "$path" ]]; then cat "$path"; return; fi
        if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
        sleep 0.1
    done
    return 1
}

./origin-fixture > origin.port 2> origin.log &
pids+=("$!")
origin_port="$(await_port origin.port "$!")"
./relay --issue-root --origin-fixture-port "$origin_port" > relay.port 2> relay.log &
pids+=("$!")
relay_port="$(await_port relay.port "$!")"

mkdir Probe.app
cp "$source_dir/SimulatorInfo.plist" Probe.app/Info.plist
cp origin.der Probe.app/
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 \
    -target arm64-apple-ios26.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$source_dir/OriginTrustProbe.swift" "$source_dir/TransferProbe.swift" \
    "$source_dir/NavigationWorkflowProbe.swift" "$source_dir/WorkflowSimulatorApp.swift" -o Probe.app/Probe \
    -framework UIKit -framework WebKit -framework Network -framework Security
codesign --force --sign - Probe.app

device_id="$(xcrun simctl create "myterm-workflows-$$" "$device_type" "$runtime")"
xcrun simctl bootstatus "$device_id" -b > boot.log 2>&1
xcrun simctl keychain "$device_id" add-root-cert "$run_dir/root.der"
xcrun simctl install "$device_id" "$run_dir/Probe.app"
app_data="$(xcrun simctl get_app_container "$device_id" "$bundle" data)"

for mode in navigation transfers; do
    SIMCTL_CHILD_MYTERM_WORKFLOW_RELAY_PORT="$relay_port" SIMCTL_CHILD_MYTERM_WORKFLOW_ORIGIN_PORT="$origin_port" \
        SIMCTL_CHILD_MYTERM_WORKFLOW_MODE="$mode" \
        SIMCTL_CHILD_MYTERM_WORKFLOW_DIRECT_DOWNLOAD="${MYTERM_WORKFLOW_DIRECT_DOWNLOAD:-0}" \
        xcrun simctl launch --terminate-running-process "$device_id" "$bundle" >&2
    path="$app_data/Documents/workflow-$mode.json"
    for _ in {1..280}; do
        if [[ -s "$path" ]]; then break; fi
        sleep 0.5
    done
    if [[ -s "$path" ]]; then
        cp "$path" "$mode.json"
    else
        printf '{"probeError":"timed out waiting for native fixture"}\n' > "$mode.json"
    fi
done
jq -n --slurpfile navigation navigation.json --slurpfile transfers transfers.json \
    '{navigation:$navigation[0],transfers:$transfers[0]}'
cat relay.log origin.log >&2
