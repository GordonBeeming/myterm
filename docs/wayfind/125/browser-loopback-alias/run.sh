#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
: "${MYTERM_RELAY_HOST:?Set the trusted loopback proxy hostname}"
: "${MYTERM_RELAY_CERT:?Set the absolute path to the trusted proxy fixture chain}"
: "${MYTERM_RELAY_KEY:?Set the absolute path to the matching proxy key}"
: "${MYTERM_RUST_REGISTRY:?Set the writable Cargo registry cache}"
run="$(mktemp -d /private/tmp/myterm-alias.XXXXXX)"
printf 'Run directory: %s\n' "$run" >&2
cd "$run"
export CLANG_MODULE_CACHE_PATH="$run/clang-cache"
image=docker.io/library/rust:1.89-bookworm
docker_cmd=(docker --context orbstack)
proxy=""
origin=""
device=""
cleanup() {
    if [[ -n "$device" ]]; then
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || true
    fi
    for container in "$origin" "$proxy"; do
        if [[ -n "$container" ]]; then
            "${docker_cmd[@]}" logs "$container" > "$container.log" 2>&1 || true
            "${docker_cmd[@]}" stop "$container" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT
build="${MYTERM_PRIVATE_LINUX_BUILD:-$run/build}"
mkdir -p "$build"
"${docker_cmd[@]}" run --rm --network none --platform linux/arm64 \
    -v "$source_dir/../browser-private-routing:/fixture:ro" -v "$build:/build" \
    -v "$MYTERM_RUST_REGISTRY:/usr/local/cargo/registry" -e CARGO_TARGET_DIR=/build \
    "$image" cargo build --locked --offline --manifest-path /fixture/Cargo.toml >&2

CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local GOCACHE="$run/go-cache" \
    go build -o origin-fixture "$source_dir/origin.go"
export MYTERM_ALIAS_HOST=app.dev.myterm.test
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=$MYTERM_ALIAS_HOST" -addext "subjectAltName=DNS:$MYTERM_ALIAS_HOST" \
    -addext 'extendedKeyUsage=serverAuth' -addext 'basicConstraints=critical,CA:FALSE' \
    -keyout origin.key -out origin.pem 2>certificate.log
openssl x509 -in origin.pem -outform der -out origin.der

proxy_name="myterm-alias-proxy-$$"
"${docker_cmd[@]}" run --rm --detach --name "$proxy_name" --publish 127.0.0.1::8443 \
    -e MYTERM_FIXTURE_LOOPBACK_ALIAS=1 -v "$build/debug:/bin-fixture:ro" \
    -v "$MYTERM_RELAY_CERT:/fixture-chain.pem:ro" -v "$MYTERM_RELAY_KEY:/fixture-key.pem:ro" \
    "$image" /bin-fixture/myterm-private-route-fixture proxy 0.0.0.0:8443 "$MYTERM_ALIAS_HOST" 127.0.0.1 3000 \
    /fixture-chain.pem /fixture-key.pem >/dev/null
proxy="$proxy_name"
origin_name="myterm-alias-origin-$$"
"${docker_cmd[@]}" run --rm --detach --name "$origin_name" --network "container:$proxy" \
    -v "$run/origin-fixture:/origin-fixture:ro" -v "$run/origin.pem:/origin.pem:ro" -v "$run/origin.key:/origin.key:ro" \
    "$image" /origin-fixture 127.0.0.1:3000 "$MYTERM_ALIAS_HOST" /origin.pem /origin.key >/dev/null
origin="$origin_name"
for _ in {1..70}; do
    if "${docker_cmd[@]}" logs "$proxy" 2>&1 | grep -q 'proxy ready' &&
          "${docker_cmd[@]}" exec "$origin" curl -ksS --max-time 1 -H "Host: $MYTERM_ALIAS_HOST" \
          https://127.0.0.1:3000/dashboard >/dev/null 2>&1; then break; fi
    sleep .1
done
port="$("${docker_cmd[@]}" port "$proxy" 8443/tcp)"
export MYTERM_ALIAS_PROXY="https://$MYTERM_RELAY_HOST:${port##*:}"

if [[ -n "${MYTERM_ALIAS_SIMULATOR:-}" ]]; then
    mkdir Probe.app
    cp "$source_dir/../browser-relay-http2/SimulatorInfo.plist" Probe.app/Info.plist
    cp origin.der Probe.app/
    xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios26.0-simulator \
        -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$source_dir/AliasProbe.swift" -o Probe.app/Probe \
        -framework UIKit -framework WebKit -framework Network -framework Security
    codesign --force --sign - Probe.app
    device="$(xcrun simctl create "myterm-alias-$$" "$MYTERM_ALIAS_SIMULATOR" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
    xcrun simctl bootstatus "$device" -b > boot.log 2>&1
    xcrun simctl install "$device" "$run/Probe.app"
    bundle=com.gordonbeeming.myterm.wayfind.proxyprobe
    data="$(xcrun simctl get_app_container "$device" "$bundle" data)"
    SIMCTL_CHILD_MYTERM_ALIAS_HOST="$MYTERM_ALIAS_HOST" SIMCTL_CHILD_MYTERM_ALIAS_PROXY="$MYTERM_ALIAS_PROXY" \
        xcrun simctl launch "$device" "$bundle" >&2
    for _ in {1..120}; do
        if [[ -s "$data/Documents/alias-results.json" ]]; then break; fi
        sleep .5
    done
    cp "$data/Documents/alias-results.json" result.json
    jq -e 'has("fixtureError") | not' result.json >/dev/null || { cat result.json >&2; exit 1; }
else
    swiftc -parse-as-library "$source_dir/AliasProbe.swift" -o probe \
        -framework AppKit -framework WebKit -framework Network -framework Security
    ./probe > result.json
fi
"${docker_cmd[@]}" logs "$origin" > origin.log 2>&1
"${docker_cmd[@]}" logs "$proxy" > proxy.log 2>&1
jq -n --slurpfile browser result.json --rawfile origin origin.log --rawfile proxy proxy.log \
    '{browser:$browser[0], originLog:($origin|split("\n")|map(select(length>0))),
      proxyLog:($proxy|split("\n")|map(select(length>0)))}'
