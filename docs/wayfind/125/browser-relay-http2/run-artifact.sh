#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$source_dir/../../../.." && pwd)"
run_dir="$(mktemp -d /private/tmp/myterm-artifact-proxy.XXXXXX)"
printf 'Run directory: %s\n' "$run_dir" >&2
cd "$run_dir"
export GOCACHE="$run_dir/go-cache"
export GOTOOLCHAIN=local
export CLANG_MODULE_CACHE_PATH="$run_dir/clang-cache"

go -C "$source_dir" build -mod=readonly -o "$run_dir/relay" relay.go
swiftc -parse-as-library -swift-version 5 "$source_dir/ArtifactProbe.swift" \
    "$repo/Sources/MyTerm/Companion/CompanionBrowserArtifact.swift" -o probe \
    -framework AppKit -framework WebKit -framework Network -framework UniformTypeIdentifiers
./probe
