#!/usr/bin/env bash
set -euo pipefail

service="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$service/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -r "$scratch"' EXIT
export MYTERM_PTY_CHECKPOINT_FIXTURE="$scratch/pty-checkpoint.json"
export MYTERM_PTY_OUTPUT_FIXTURE="$scratch/pty-continuation.bin"
export MYTERM_DENSE_CHECKPOINT_FIXTURE="$scratch/dense-terminal-checkpoint.json"
export MYTERM_PENDING_GRAPHICS_CHECKPOINT_FIXTURE="$scratch/pending-graphics-checkpoint.json"
export MYTERM_RASTER_CHECKPOINT_FIXTURE="$scratch/raster-checkpoint.json"
export MYTERM_BOUNDED_CHECKPOINT_FIXTURE="$scratch/bounded-history-checkpoint.json"
export MYTERM_LARGE_GRAPHICS_CHECKPOINT_FIXTURE="$scratch/large-graphics-checkpoint.json"
export MYTERM_RESIZE_CHECKPOINT_FIXTURE="$scratch/resize-checkpoint.json"
python3 "$service/dependencies/prepare.py"
export CARGO_TARGET_DIR="$service/target"
cargo +1.99.1 test --locked --manifest-path "$service/Cargo.toml"
cargo +1.99.1 test --locked --manifest-path "$root/Services/local-terminal/Cargo.toml" -- --test-threads=1
swift test --package-path "$root" --filter 'TerminalCheckpointTests|WezTermCheckpointTests'
