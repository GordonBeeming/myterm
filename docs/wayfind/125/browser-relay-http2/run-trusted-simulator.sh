#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
device_type="${1:-com.apple.CoreSimulator.SimDeviceType.iPhone-11}"
runtime="${2:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
domain_matching="${MYTERM_PROBE_DOMAINS:-explicit}"
case "$domain_matching" in
    explicit|default) ;;
    *) printf 'MYTERM_PROBE_DOMAINS must be explicit or default.\n' >&2; exit 2 ;;
esac
transport="${MYTERM_PROBE_TRANSPORT:-http2}"
case "$transport" in
    http2|http3) ;;
    *) printf 'MYTERM_PROBE_TRANSPORT must be http2 or http3.\n' >&2; exit 2 ;;
esac
run_dir="$(mktemp -d /private/tmp/myterm-browser-trusted.XXXXXX)"
printf 'Run directory: %s\n' "$run_dir" >&2
cd "$run_dir"
export GOCACHE="$run_dir/go-cache"
export GOTOOLCHAIN=local
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"
bundle=com.gordonbeeming.myterm.wayfind.proxyprobe

go -C "$source_dir" build -mod=readonly -o "$run_dir/relay" relay.go
mkdir Probe.app
cp "$source_dir/SimulatorInfo.plist" Probe.app/Info.plist
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 \
    -target arm64-apple-ios26.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$source_dir/probe.swift" "$source_dir/ProfileProbe.swift" -o Probe.app/Probe \
    -framework UIKit -framework WebKit -framework Network -framework Security
codesign --force --sign - Probe.app

device_id=""
relay_pid=""
secondary_pid=""
secondary_port=""
profile_url=""
profile_id=""
cleanup() {
    if [[ -n "$device_id" ]]; then
        xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "$relay_pid" ]]; then kill "$relay_pid" 2>/dev/null || true; fi
    if [[ -n "$secondary_pid" ]]; then kill "$secondary_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
http3=false
if [[ "$transport" == http3 ]]; then http3=true; fi
./relay --issue-root --http3="$http3" > relay.port 2> relay.log &
relay_pid=$!
for _ in {1..50}; do
    if [[ -s relay.port ]]; then break; fi
    if ! kill -0 "$relay_pid" 2>/dev/null; then cat relay.log >&2; exit 1; fi
    sleep 0.1
done
relay_port="$(cat relay.port)"
[[ -n "$relay_port" ]] || { cat relay.log >&2; exit 1; }

if [[ "${MYTERM_PROBE_PROFILES:-0}" == 1 ]]; then
    if [[ "$http3" == true ]]; then
        printf 'Profile checks require HTTP/2.\n' >&2
        exit 2
    fi
    mkdir secondary
    (cd secondary && exec ../relay --issue-root --label SECONDARY_RELAY_FIXTURE) \
        > secondary/relay.port 2> secondary/relay.log &
    secondary_pid=$!
    for _ in {1..50}; do
        if [[ -s secondary/relay.port ]]; then break; fi
        if ! kill -0 "$secondary_pid" 2>/dev/null; then cat secondary/relay.log >&2; exit 1; fi
        sleep 0.1
    done
    secondary_port="$(cat secondary/relay.port)"
    [[ -n "$secondary_port" ]] || exit 1
fi

device_id="$(xcrun simctl create "myterm-trusted-proxy-$$" "$device_type" "$runtime")"
xcrun simctl bootstatus "$device_id" -b > boot.log 2>&1
xcrun simctl keychain "$device_id" add-root-cert "$run_dir/root.der"
if [[ -n "$secondary_port" ]]; then
    xcrun simctl keychain "$device_id" add-root-cert "$run_dir/secondary/root.der"
fi
xcrun simctl install "$device_id" "$run_dir/Probe.app"
app_data="$(xcrun simctl get_app_container "$device_id" "$bundle" data)"
result="$app_data/Documents/routing-result.json"

launch_probe() {
    local mode="$1"
    SIMCTL_CHILD_MYTERM_PROBE_PORT="$relay_port" SIMCTL_CHILD_MYTERM_PROBE_STATE="$mode" \
        SIMCTL_CHILD_MYTERM_PROBE_DOMAINS="$domain_matching" SIMCTL_CHILD_MYTERM_PROBE_TRANSPORT="$transport" \
        SIMCTL_CHILD_MYTERM_PROBE_WEBRTC="${MYTERM_PROBE_WEBRTC:-0}" \
        SIMCTL_CHILD_MYTERM_PROBE_SECONDARY_PORT="$secondary_port" \
        SIMCTL_CHILD_MYTERM_PROBE_PROFILE_URL="$profile_url" SIMCTL_CHILD_MYTERM_PROBE_PROFILE_ID="$profile_id" \
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
if [[ -n "$secondary_port" ]]; then
    profile_url="$(jq -er '.profiles.url' running.json)"
    profile_id="$(jq -er '.profiles.secondaryStoreID' running.json)"
    launch_probe profile-reopen
fi
kill "$relay_pid"
wait "$relay_pid" 2>/dev/null || true
relay_pid=""
launch_probe stopped

if [[ -n "$secondary_port" ]]; then
    jq -s . running.json profile-reopen.json stopped.json
else
    jq -s . running.json stopped.json
fi
cat relay.log >&2
if [[ -n "$secondary_pid" ]]; then cat secondary/relay.log >&2; fi
