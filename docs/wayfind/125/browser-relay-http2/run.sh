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
swiftc -parse-as-library -swift-version 5 "$source_dir/probe.swift" -o probe \
    -framework AppKit -framework WebKit -framework Network -framework Security

relay_options=()
if [[ -n "${MYTERM_RELAY_HOST:-}" ]]; then
    relay_options+=(--cert "${MYTERM_RELAY_CERT:?Provide a PEM certificate chain}" --key "${MYTERM_RELAY_KEY:?Provide a PEM fixture key}")
fi
if [[ "${MYTERM_PROBE_TRANSPORT:-http2}" == http3 ]]; then relay_options+=(--http3); fi
./relay ${relay_options[@]+"${relay_options[@]}"} > relay.port 2> relay.log &
relay_pid=$!
trap 'kill "$relay_pid" 2>/dev/null || true' EXIT
for _ in {1..50}; do
    if [[ -s relay.port ]]; then break; fi
    if ! kill -0 "$relay_pid" 2>/dev/null; then
        cat relay.log >&2
        exit 1
    fi
    sleep 0.1
done
relay_port="$(cat relay.port)"
if [[ -z "${MYTERM_RELAY_HOST:-}" && "${MYTERM_PROBE_TRANSPORT:-http2}" == http2 ]]; then
    ./tls-control "$relay_port" >&2
fi
./probe "$relay_port" running > running.json

kill "$relay_pid"
wait "$relay_pid" 2>/dev/null || true
trap - EXIT
./probe "$relay_port" stopped > stopped.json

jq -s . running.json stopped.json
printf 'Run directory: %s\n' "$run_dir" >&2
cat relay.log >&2
