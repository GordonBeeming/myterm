#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
: "${MYTERM_RELAY_HOST:?Set the trusted loopback fixture hostname}"
: "${MYTERM_RELAY_CERT:?Set the absolute path to the trusted fixture chain}"
: "${MYTERM_RELAY_KEY:?Set the absolute path to the matching fixture key}"
: "${MYTERM_RUST_REGISTRY:?Set a writable Cargo registry cache with the locked fixture dependencies}"
run_dir="$(mktemp -d /private/tmp/myterm-private-routes.XXXXXX)"
printf 'Run directory: %s\n' "$run_dir" >&2
cd "$run_dir"
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"
image="docker.io/library/rust:1.89-bookworm"
network="myterm-route-fixture-$$"
origin="myterm-private-origin-$$"
proxy="myterm-private-proxy-$$"
subnet_prefix="${MYTERM_PRIVATE_SUBNET_PREFIX:-10.253.160}"
host="private-origin.myterm.test"
origin_ip="$subnet_prefix.20"
proxy_ip="$subnet_prefix.10"
origin_port=8192
device=""
docker_cmd=(docker --context orbstack)
proxy_launched=false
origin_launched=false
network_created=false

cleanup() {
    if [[ -n "$device" ]]; then
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || true
    fi
    if [[ "$proxy_launched" == true ]]; then "${docker_cmd[@]}" stop "$proxy" >/dev/null 2>&1 || true; fi
    if [[ "$origin_launched" == true ]]; then "${docker_cmd[@]}" stop "$origin" >/dev/null 2>&1 || true; fi
    if [[ "$network_created" == true ]]; then "${docker_cmd[@]}" network rm "$network" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

build_dir="${MYTERM_PRIVATE_LINUX_BUILD:-$run_dir/build}"
mkdir -p "$build_dir"
"${docker_cmd[@]}" run --rm --network none --platform linux/arm64 \
    -v "$source_dir:/fixture:ro" -v "$build_dir:/build" \
    -v "$MYTERM_RUST_REGISTRY:/usr/local/cargo/registry" -e CARGO_TARGET_DIR=/build \
    "$image" cargo build --locked --offline --manifest-path /fixture/Cargo.toml >&2

"${docker_cmd[@]}" network create --subnet "$subnet_prefix.0/24" "$network" >/dev/null
network_created=true
"${docker_cmd[@]}" run --rm --detach --name "$origin" --network "$network" --ip "$origin_ip" \
    --network-alias "$host" -v "$build_dir/debug:/bin-fixture:ro" \
    "$image" /bin-fixture/myterm-private-route-fixture origin "0.0.0.0:$origin_port" "$proxy_ip" >/dev/null
origin_launched=true

"${docker_cmd[@]}" run --rm --detach --name "$proxy" --network "$network" --ip "$proxy_ip" \
    --publish 127.0.0.1::8443 -v "$build_dir/debug:/bin-fixture:ro" \
    -v "$MYTERM_RELAY_CERT:/fixture-chain.pem:ro" -v "$MYTERM_RELAY_KEY:/fixture-key.pem:ro" \
    "$image" /bin-fixture/myterm-private-route-fixture proxy 0.0.0.0:8443 "$host" "$origin_ip" "$origin_port" \
    /fixture-chain.pem /fixture-key.pem >/dev/null
proxy_launched=true

for _ in {1..60}; do
    if "${docker_cmd[@]}" logs "$origin" 2>&1 | grep -q 'origin ready' &&
       "${docker_cmd[@]}" logs "$proxy" 2>&1 | grep -q 'proxy ready'; then
        break
    fi
    sleep 0.1
done
proxy_port="$("${docker_cmd[@]}" port "$proxy" 8443/tcp)"
proxy_port="${proxy_port##*:}"
export MYTERM_PRIVATE_PROXY="https://$MYTERM_RELAY_HOST:$proxy_port"
export MYTERM_PRIVATE_NAME="$host" MYTERM_PRIVATE_IP="$origin_ip" MYTERM_PRIVATE_ORIGIN_PORT="$origin_port"

direct_origin_status="$("${docker_cmd[@]}" run --rm --network "$network" "$image" \
    curl --silent --show-error --max-time 4 --output /dev/null --write-out '%{http_code}' "http://$host:$origin_port/private-route")"
if [[ "$direct_origin_status" != 403 ]]; then
    printf 'Direct source control unexpectedly returned %s.\n' "$direct_origin_status" >&2
    exit 1
fi

swiftc -parse-as-library "$source_dir/PrivateRouteProbe.swift" -o private-route-probe \
    -framework AppKit -framework WebKit -framework Network
./private-route-probe > mac.json

if [[ -n "${MYTERM_PRIVATE_SIMULATOR_TYPE:-}" ]]; then
    bundle=com.gordonbeeming.myterm.wayfind.proxyprobe
    mkdir Probe.app
    cp "$source_dir/../browser-relay-http2/SimulatorInfo.plist" Probe.app/Info.plist
    xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios26.0-simulator \
        -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$source_dir/PrivateRouteProbe.swift" -o Probe.app/Probe \
        -framework UIKit -framework WebKit -framework Network
    codesign --force --sign - Probe.app
    device="$(xcrun simctl create "myterm-private-routes-$$" "$MYTERM_PRIVATE_SIMULATOR_TYPE" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
    xcrun simctl bootstatus "$device" -b > boot.log 2>&1
    xcrun simctl install "$device" "$run_dir/Probe.app"
    app_data="$(xcrun simctl get_app_container "$device" "$bundle" data)"
    SIMCTL_CHILD_MYTERM_PRIVATE_PROXY="$MYTERM_PRIVATE_PROXY" SIMCTL_CHILD_MYTERM_PRIVATE_NAME="$host" \
        SIMCTL_CHILD_MYTERM_PRIVATE_IP="$origin_ip" SIMCTL_CHILD_MYTERM_PRIVATE_ORIGIN_PORT="$origin_port" \
        xcrun simctl launch "$device" "$bundle" >&2
    for _ in {1..100}; do
        if [[ -s "$app_data/Documents/private-routes.json" ]]; then break; fi
        sleep 0.5
    done
    cp "$app_data/Documents/private-routes.json" simulator.json
fi

"${docker_cmd[@]}" logs "$proxy" > proxy.log 2>&1
"${docker_cmd[@]}" stop "$proxy" >/dev/null
proxy_launched=false
./private-route-probe > mac-offline.json
client_has_dns_answer=false
if dscacheutil -q host -a name "$host" | grep -q 'ip_address:'; then client_has_dns_answer=true; fi
"${docker_cmd[@]}" logs "$origin" > origin.log 2>&1
"${docker_cmd[@]}" exec "$origin" uname -s -m > server-os
if [[ -f simulator.json ]]; then
    simulator_record=simulator.json
else
    simulator_record=/dev/null
fi
jq -n --arg direct "$direct_origin_status" --argjson clientDNS "$client_has_dns_answer" --rawfile platform server-os \
    --slurpfile mac mac.json --slurpfile offline mac-offline.json --slurpfile sim "$simulator_record" --rawfile proxy proxy.log --rawfile origin origin.log \
    '{linuxPlatform:($platform|rtrimstr("\n")),directSourceStatus:($direct|tonumber),
      macOS:$mac[0],macOSWithoutProxy:$offline[0],iOSSimulator:$sim[0],macOSHasPrivateDNSAnswer:$clientDNS,
      proxyLog:($proxy|split("\n")|map(select(length>0))),
      originLog:($origin|split("\n")|map(select(length>0)))}'
