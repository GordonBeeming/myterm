#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
run_dir="$(mktemp -d /private/tmp/myterm-browser-h2.XXXXXX)"
cd "$run_dir"
export TMPDIR="$run_dir"
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"
export GOCACHE="$run_dir/go-cache"
export GOTOOLCHAIN=local

go -C "$source_dir" build -mod=readonly -o "$run_dir/relay" relay.go
go -C "$source_dir" build -mod=readonly -o "$run_dir/tls-control" ./control
swiftc -parse-as-library -swift-version 5 "$source_dir/probe.swift" "$source_dir/ProfileProbe.swift" -o probe \
    -framework AppKit -framework WebKit -framework Network -framework Security

relay_options=()
if [[ -n "${MYTERM_RELAY_HOST:-}" ]]; then
    relay_options+=(--cert "${MYTERM_RELAY_CERT:?Provide a PEM certificate chain}" --key "${MYTERM_RELAY_KEY:?Provide a PEM fixture key}")
fi
if [[ "${MYTERM_PROBE_TRANSPORT:-http2}" == http3 ]]; then relay_options+=(--http3); fi
./relay ${relay_options[@]+"${relay_options[@]}"} > relay.port 2> relay.log &
relay_pid=$!
secondary_pid=""
cleanup() {
    if [[ -n "$relay_pid" ]]; then kill "$relay_pid" 2>/dev/null || true; fi
    if [[ -n "$secondary_pid" ]]; then kill "$secondary_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
for _ in {1..50}; do
    if [[ -s relay.port ]]; then break; fi
    if ! kill -0 "$relay_pid" 2>/dev/null; then
        cat relay.log >&2
if [[ -n "$secondary_pid" ]]; then cat secondary/relay.log >&2; fi
        exit 1
    fi
    sleep 0.1
done
relay_port="$(cat relay.port)"
if [[ -z "${MYTERM_RELAY_HOST:-}" && "${MYTERM_PROBE_TRANSPORT:-http2}" == http2 ]]; then
    ./tls-control "$relay_port" >&2
fi
if [[ "${MYTERM_PROBE_PROFILES:-0}" == 1 ]]; then
    if [[ -z "${MYTERM_RELAY_HOST:-}" || "${MYTERM_PROBE_TRANSPORT:-http2}" != http2 ]]; then
        printf 'Profile checks require trusted desktop TLS and HTTP/2.\n' >&2
        exit 2
    fi
    mkdir secondary
    (cd secondary && exec ../relay "${relay_options[@]}" --label SECONDARY_RELAY_FIXTURE) \
        > secondary/relay.port 2> secondary/relay.log &
    secondary_pid=$!
    for _ in {1..50}; do
        if [[ -s secondary/relay.port ]]; then break; fi
        if ! kill -0 "$secondary_pid" 2>/dev/null; then cat secondary/relay.log >&2; exit 1; fi
        sleep 0.1
    done
    MYTERM_PROBE_SECONDARY_PORT="$(cat secondary/relay.port)"
    [[ -n "$MYTERM_PROBE_SECONDARY_PORT" ]] || exit 1
    export MYTERM_PROBE_SECONDARY_PORT
fi
./probe "$relay_port" running > running.json

kill "$relay_pid"
wait "$relay_pid" 2>/dev/null || true
relay_pid=""
./probe "$relay_port" stopped > stopped.json

jq -s . running.json stopped.json
printf 'Run directory: %s\n' "$run_dir" >&2
cat relay.log >&2
if [[ -n "$secondary_pid" ]]; then cat secondary/relay.log >&2; fi
