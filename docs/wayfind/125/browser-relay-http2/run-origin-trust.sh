#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
: "${MYTERM_RELAY_HOST:?Set the trusted loopback relay hostname}"
: "${MYTERM_RELAY_CERT:?Set the absolute path to a trusted fixture chain}"
: "${MYTERM_RELAY_KEY:?Set the absolute path to the matching fixture key}"
run_dir="$(mktemp -d /private/tmp/myterm-origin-trust.XXXXXX)"
printf 'Run directory: %s\n' "$run_dir" >&2
cd "$run_dir"
export GOCACHE="$run_dir/go-cache"
export GOTOOLCHAIN=local
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"

go -C "$source_dir" build -mod=readonly -o "$run_dir/relay" relay.go
go -C "$source_dir" build -mod=readonly -o "$run_dir/origin-fixture" ./origin
swiftc -parse-as-library "$source_dir/OriginTrustProbe.swift" "$source_dir/TransferProbe.swift" -o probe \
    -framework AppKit -framework WebKit -framework Network -framework Security

pids=()
cleanup() { for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done; }
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
mkdir unrelated
(cd unrelated && exec ../origin-fixture) > unrelated/port 2> unrelated/origin.log &
pids+=("$!")
await_port unrelated/port "$!" >/dev/null
for label in primary secondary; do
    ./relay --cert "$MYTERM_RELAY_CERT" --key "$MYTERM_RELAY_KEY" --origin-fixture-port "$origin_port" \
        > "$label.port" 2> "$label.log" &
    pids+=("$!")
    await_port "$label.port" "$!" >/dev/null
done
./probe "$MYTERM_RELAY_HOST" "$(cat primary.port)" "$(cat secondary.port)" "$origin_port"
cat primary.log secondary.log origin.log >&2
