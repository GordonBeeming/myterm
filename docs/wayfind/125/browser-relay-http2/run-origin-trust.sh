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
swiftc -parse-as-library "$source_dir/OriginTrustProbe.swift" "$source_dir/TransferProbe.swift" \
    "$source_dir/NavigationWorkflowProbe.swift" "$source_dir/OutageProbe.swift" -o probe \
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
primary_pid=""
for label in primary secondary; do
    ./relay --cert "$MYTERM_RELAY_CERT" --key "$MYTERM_RELAY_KEY" --origin-fixture-port "$origin_port" \
        > "$label.port" 2> "$label.log" &
    pids+=("$!")
    await_port "$label.port" "$!" >/dev/null
    if [[ "$label" == primary ]]; then primary_pid="$!"; fi
done
primary_port="$(cat primary.port)"
secondary_port="$(cat secondary.port)"
if [[ "${MYTERM_PROBE_OUTAGE:-0}" == 1 ]]; then
    ./probe "$MYTERM_RELAY_HOST" "$primary_port" "$secondary_port" "$origin_port" > outage-result.json &
    probe_pid="$!"
    pids+=("$probe_pid")
    await_port outage-ready "$probe_pid" >/dev/null
    kill "$primary_pid"
    wait "$primary_pid" 2>/dev/null || true
    printf 'stopped\n' > outage-stopped
    await_port outage-observed "$probe_pid" >/dev/null
    ./relay --cert "$MYTERM_RELAY_CERT" --key "$MYTERM_RELAY_KEY" \
        --origin-fixture-port "$origin_port" --bind-port "$primary_port" > restored.port 2> restored.log &
    pids+=("$!")
    await_port restored.port "$!" >/dev/null
    printf 'restored\n' > outage-restored
    wait "$probe_pid"
    cat outage-result.json
    cat restored.log >&2
else
    ./probe "$MYTERM_RELAY_HOST" "$primary_port" "$secondary_port" "$origin_port"
fi
cat primary.log secondary.log origin.log >&2
