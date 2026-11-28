#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SCRIPT="$ROOT_DIR/run.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/myterm-channel-isolation.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

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

development_support="$TEST_ROOT/application-support"
development_plan="$({
  MYTERM_APPLICATION_SUPPORT_DIRECTORY="$development_support" \
  "$RUN_SCRIPT" --print-plan
})"

assert_line "channel=development" "$development_plan"
assert_line "app_name=myterm-dev" "$development_plan"
assert_line "bundle_id=com.gordonbeeming.myterm.dev" "$development_plan"
assert_line "app_bundle=$ROOT_DIR/dist/myterm-dev.app" "$development_plan"
assert_line "workspace_state_path=$development_support/myterm-dev/workspace-state.json" "$development_plan"
assert_line "instance_policy=focus-existing" "$development_plan"
assert_line "build_configuration=debug" "$development_plan"

assert_no_line "process_kill_target=myterm" "$development_plan"
assert_no_line "bundle_id=com.gordonbeeming.myterm" "$development_plan"
assert_no_line "app_bundle=$ROOT_DIR/dist/myterm.app" "$development_plan"
assert_no_line "workspace_state_path=$development_support/myterm/workspace-state.json" "$development_plan"

production_support="$TEST_ROOT/production-support"
production_plan="$({
  MYTERM_APPLICATION_SUPPORT_DIRECTORY="$production_support" \
  "$RUN_SCRIPT" --prod --print-plan
})"

assert_line "channel=production" "$production_plan"
assert_line "app_name=myterm" "$production_plan"
assert_line "bundle_id=com.gordonbeeming.myterm" "$production_plan"
assert_line "app_bundle=$ROOT_DIR/dist/myterm.app" "$production_plan"
assert_line "workspace_state_path=$production_support/myterm/workspace-state.json" "$production_plan"
assert_line "instance_policy=focus-existing" "$production_plan"
assert_line "build_configuration=release" "$production_plan"

assert_no_line "local_rust_workspaces=1" "$production_plan"
assert_no_line "rust_release_rehearsal=1" "$production_plan"

shipping_plan="$(MYTERM_DISTRIBUTION=1 MYTERM_SHIP_RUST_WORKSPACES=1 "$RUN_SCRIPT" --prod --print-plan)"
assert_line "channel=production" "$shipping_plan"
assert_line "bundle_id=com.gordonbeeming.myterm" "$shipping_plan"
assert_line "app_bundle=$ROOT_DIR/dist/myterm.app" "$shipping_plan"
assert_line "rust_server=$ROOT_DIR/dist/myterm.app/Contents/MacOS/myterm-local-terminal" "$shipping_plan"
assert_line "build_configuration=release" "$shipping_plan"
assert_line "ship_rust_workspaces=1" "$shipping_plan"
assert_no_line "rust_release_rehearsal=1" "$shipping_plan"

if MYTERM_DISTRIBUTION=0 MYTERM_SHIP_RUST_WORKSPACES=1 "$RUN_SCRIPT" --prod --print-plan > /dev/null 2>&1; then
  echo "production Rust packaging was accepted without a distribution build" >&2
  exit 1
fi

if MYTERM_DISTRIBUTION=1 MYTERM_SHIP_RUST_WORKSPACES=1 "$RUN_SCRIPT" --prod > /dev/null 2>&1; then
  echo "production Rust packaging accepted a launch request" >&2
  exit 1
fi

rehearsal_support="$TEST_ROOT/rehearsal-support"
rehearsal_plan="$(MYTERM_APPLICATION_SUPPORT_DIRECTORY="$rehearsal_support" "$RUN_SCRIPT" --rust-release-rehearsal --print-plan)"
assert_line "channel=production" "$rehearsal_plan"
assert_line "app_name=myterm" "$rehearsal_plan"
assert_line "bundle_id=com.gordonbeeming.myterm.rust-rehearsal" "$rehearsal_plan"
assert_line "app_bundle=$ROOT_DIR/dist/rust-release-rehearsal/myterm.app" "$rehearsal_plan"
assert_line "workspace_state_path=$rehearsal_support/myterm/workspace-state.json" "$rehearsal_plan"
assert_line "build_configuration=release" "$rehearsal_plan"
assert_line "local_rust_workspaces=1" "$rehearsal_plan"
assert_line "rust_release_rehearsal=1" "$rehearsal_plan"

if "$RUN_SCRIPT" --prod --rust-release-rehearsal --print-plan > /dev/null 2>&1; then
  echo "the release rehearsal was accepted in the existing production packaging route" >&2
  exit 1
fi

if MYTERM_DISTRIBUTION=1 "$RUN_SCRIPT" --rust-release-rehearsal --print-plan > /dev/null 2>&1; then
  echo "the release rehearsal was accepted in the distribution pipeline" >&2
  exit 1
fi

no_support_status=0
MYTERM_APPLICATION_SUPPORT_DIRECTORY='' "$RUN_SCRIPT" --rust-release-rehearsal > "$TEST_ROOT/missing-support.log" 2>&1 || no_support_status=$?
[[ "$no_support_status" == 2 ]]
grep -Fq "Set MYTERM_APPLICATION_SUPPORT_DIRECTORY" "$TEST_ROOT/missing-support.log"

cp "$ROOT_DIR/Packaging/Info.plist" "$TEST_ROOT/development.plist"
cp "$ROOT_DIR/Packaging/Info.plist" "$TEST_ROOT/production.plist"
bash "$ROOT_DIR/script/configure_url_handlers.sh" development com.gordonbeeming.myterm.dev "$TEST_ROOT/development.plist"
bash "$ROOT_DIR/script/configure_url_handlers.sh" production com.gordonbeeming.myterm "$TEST_ROOT/production.plist"
python3 - "$TEST_ROOT" <<'PY'
from pathlib import Path
import plistlib,sys
root=Path(sys.argv[1])
def schemes(channel):
    data=plistlib.loads((root/(channel+'.plist')).read_bytes())
    return {s for t in data['CFBundleURLTypes'] for s in t['CFBundleURLSchemes']}
assert schemes('development') == {'myterm-dev'}, schemes('development')
assert schemes('production') == {'myterm','http','https','ssh'}, schemes('production')
PY
printf 'channel isolation plan and URL registration checks passed\n'
