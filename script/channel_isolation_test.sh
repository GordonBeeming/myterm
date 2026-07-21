#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SCRIPT="$ROOT_DIR/run.sh"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/myterm-channel-isolation.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

assert_line() {
  local expected="$1"
  local output="$2"
  if ! grep -Fqx "$expected" <<<"$output"; then
    printf 'expected plan line: %s\nplan:\n%s\n' "$expected" "$output" >&2
    exit 1
  fi
}

assert_no_line() {
  local unexpected="$1"
  local output="$2"
  if grep -Fqx "$unexpected" <<<"$output"; then
    printf 'unexpected plan line: %s\nplan:\n%s\n' "$unexpected" "$output" >&2
    exit 1
  fi
}

development_support="$TEST_HOME/application-support"
development_plan="$({
  HOME="$TEST_HOME/home" \
  MYTERM_APPLICATION_SUPPORT_DIRECTORY="$development_support" \
  "$RUN_SCRIPT" --print-plan
})"

assert_line "channel=development" "$development_plan"
assert_line "app_name=myterm-dev" "$development_plan"
assert_line "bundle_id=com.gordonbeeming.myterm.dev" "$development_plan"
assert_line "app_bundle=$ROOT_DIR/dist/myterm-dev.app" "$development_plan"
assert_line "workspace_state_path=$development_support/myterm-dev/workspace-state.json" "$development_plan"
assert_line "process_kill_target=myterm-dev" "$development_plan"
assert_line "build_configuration=debug" "$development_plan"

assert_no_line "process_kill_target=myterm" "$development_plan"
assert_no_line "bundle_id=com.gordonbeeming.myterm" "$development_plan"
assert_no_line "app_bundle=$ROOT_DIR/dist/myterm.app" "$development_plan"
assert_no_line "workspace_state_path=$development_support/myterm/workspace-state.json" "$development_plan"

production_support="$TEST_HOME/production-support"
production_plan="$({
  HOME="$TEST_HOME/home" \
  MYTERM_APPLICATION_SUPPORT_DIRECTORY="$production_support" \
  "$RUN_SCRIPT" --prod --print-plan
})"

assert_line "channel=production" "$production_plan"
assert_line "app_name=myterm" "$production_plan"
assert_line "bundle_id=com.gordonbeeming.myterm" "$production_plan"
assert_line "app_bundle=$ROOT_DIR/dist/myterm.app" "$production_plan"
assert_line "workspace_state_path=$production_support/myterm/workspace-state.json" "$production_plan"
assert_line "process_kill_target=myterm" "$production_plan"
assert_line "build_configuration=release" "$production_plan"

printf 'channel isolation plan checks passed\n'
