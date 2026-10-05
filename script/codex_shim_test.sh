#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/old resources"
cp "$root/Resources/codex" "$root/Resources/codex-statusline" "$root/Resources/myterm-codex" "$scratch/old resources/"
cat > "$scratch/bin/codex" <<'MOCK'
#!/bin/sh
set -eu
if [ "${1:-}" = '--help' ]; then printf '%s\n' '--no-daemon'; exit 0; fi
printf '%s\n' "$@" > "$MYTERM_TEST_ARGS"
printf '%s' "${MYTERM_CODEX_LAUNCHER:-}" > "$MYTERM_TEST_LAUNCHER"
MOCK
cp "$scratch/bin/codex" "$scratch/bin/codex-statusline"
chmod +x "$scratch/bin/"*
export MYTERM_TEST_ARGS="$scratch/args" MYTERM_TEST_LAUNCHER="$scratch/launcher"
export PATH="$root/Resources:$scratch/old resources:$scratch/bin:/usr/bin:/bin"
check() {
  local expected=$1
  shift
  printf '%s\n' "$@" > "$scratch/expected"
  cmp "$scratch/expected" "$MYTERM_TEST_ARGS"
  test "$(cat "$MYTERM_TEST_LAUNCHER")" = "$expected"
}
unset MYTERM_PANE_ID MYTERM_CODEX_LAUNCHER
codex resume abc
check '' resume abc
export MYTERM_PANE_ID=probe
codex resume abc
check codex --no-daemon resume abc
codex-statusline resume abc
check codex-statusline --no-daemon resume abc
codex resume --no-daemon abc
check codex resume --no-daemon abc
codex resume --remote unix:// abc
check codex resume --remote unix:// abc
codex exec 'echo test'
check codex exec 'echo test'
codex -m review resume abc
check codex --no-daemon -m review resume abc
codex -C '/tmp/a project' resume abc
check codex --no-daemon -C '/tmp/a project' resume abc
codex -- '--remote'
check codex --no-daemon -- '--remote'
printf '%s\n' 'Codex launcher checks passed'
