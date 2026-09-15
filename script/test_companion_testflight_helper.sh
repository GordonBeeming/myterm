#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myterm-testflight-helper.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

render_configuration() {
  local output_dir="$1" build_number="$2" push_origin="$3"
  local app_profile="${4:-MyTerm App & Store}"
  local notification_profile="${5:-MyTerm Notification <Store>}"
  local api_key_id="${6:-KEY1234567}"
  env \
    GITHUB_WORKSPACE="$ROOT_DIR" \
    RUNNER_TEMP="$TEST_ROOT" \
    MYTERM_TESTFLIGHT_OUTPUT_DIR="$output_dir" \
    APPLE_TEAM_ID="TEAM123456" \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_NAME="$app_profile" \
    NOTIFICATION_PROVISIONING_PROFILE_NAME="$notification_profile" \
    APP_STORE_CONNECT_API_KEY_ID="$api_key_id" \
    APP_STORE_CONNECT_ISSUER_ID="00000000-0000-0000-0000-000000000000" \
    BUILD_NUMBER="$build_number" \
    MYTERM_PUSH_GATEWAY_ORIGIN="$push_origin" \
    bash "$ROOT_DIR/script/deploy_companion_testflight.sh" --render-only
}

render_configuration "$TEST_ROOT/output" "42" "https://push.example.test"

ruby -ryaml - "$TEST_ROOT/output/Companion/project-ci.yml" <<'RUBY'
spec = YAML.load_file(ARGV[0])
abort "app profile missing" unless spec.dig("settings", "base", "MYTERM_APP_PROVISIONING_PROFILE") == "MyTerm App & Store"
abort "notification profile missing" unless spec.dig("settings", "base", "MYTERM_NOTIFICATION_PROVISIONING_PROFILE") == "MyTerm Notification <Store>"
abort "app profile indirection missing" unless spec.dig("targets", "MyTermCompanion", "settings", "configs", "Release", "PROVISIONING_PROFILE_SPECIFIER") == "$(MYTERM_APP_PROVISIONING_PROFILE)"
abort "notification profile indirection missing" unless spec.dig("targets", "MyTermNotificationService", "settings", "configs", "Release", "PROVISIONING_PROFILE_SPECIFIER") == "$(MYTERM_NOTIFICATION_PROVISIONING_PROFILE)"
abort "team missing" unless spec.dig("settings", "base", "DEVELOPMENT_TEAM") == "TEAM123456"
abort "push origin missing" unless spec.dig("settings", "base", "MYTERM_PUSH_GATEWAY_ORIGIN") == "https://push.example.test"
abort "app package is not absolute" unless spec.dig("packages", "MyTerm", "path").start_with?("/")
RUBY

EXPORT_OPTIONS="$TEST_ROOT/output/ExportOptions.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_OPTIONS")" == "app-store-connect" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles:com.gordonbeeming.myterm.companion' "$EXPORT_OPTIONS")" == "MyTerm App & Store" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles:com.gordonbeeming.myterm.companion.notifications' "$EXPORT_OPTIONS")" == "MyTerm Notification <Store>" ]]

if render_configuration "$TEST_ROOT/invalid-build" "0" "" >"$TEST_ROOT/invalid-build.log" 2>&1; then
  echo "The renderer accepted an invalid build number." >&2
  exit 1
fi
grep -F "BUILD_NUMBER must be a positive integer." "$TEST_ROOT/invalid-build.log" >/dev/null

invalid_origin_index=0
for invalid_origin in \
  "http://push.example.test" \
  "https://user:password@push.example.test" \
  "https://push.example.test/path" \
  "https://push.example.test?token=x" \
  "https://push.example.test?" \
  "https://push.example.test/#fragment" \
  "https://push.example.test/#" \
  "https:///" \
  "https://push.example.test:0" \
  "https://push.example.test:65536" \
  "https://push.example.test:invalid"; do
  invalid_origin_index=$((invalid_origin_index + 1))
  invalid_output="$TEST_ROOT/invalid-origin-$invalid_origin_index"
  invalid_log="$TEST_ROOT/invalid-origin-$invalid_origin_index.log"
  if render_configuration "$invalid_output" "43" "$invalid_origin" >"$invalid_log" 2>&1; then
    echo "The renderer accepted invalid push gateway origin: $invalid_origin" >&2
    exit 1
  fi
  grep -F "MYTERM_PUSH_GATEWAY_ORIGIN must be empty or an HTTPS origin without credentials, a path, query, or fragment." "$invalid_log" >/dev/null
done

render_configuration "$TEST_ROOT/no-push" "44" "" >/dev/null
ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0]).dig("settings", "base", "MYTERM_PUSH_GATEWAY_ORIGIN") == ""' "$TEST_ROOT/no-push/Companion/project-ci.yml"

render_configuration "$TEST_ROOT/normalized-push" "47" "HTTPS://PUSH.EXAMPLE.TEST:443/" >/dev/null
ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0]).dig("settings", "base", "MYTERM_PUSH_GATEWAY_ORIGIN") == "HTTPS://PUSH.EXAMPLE.TEST:443/"' "$TEST_ROOT/normalized-push/Companion/project-ci.yml"

if render_configuration "$TEST_ROOT/invalid-key" "45" "" "App" "Notification" "../BADKEY" >"$TEST_ROOT/invalid-key.log" 2>&1; then
  echo "The renderer accepted an unsafe App Store Connect key identifier." >&2
  exit 1
fi
grep -F "APP_STORE_CONNECT_API_KEY_ID must be a 10-character key identifier." "$TEST_ROOT/invalid-key.log" >/dev/null

mkdir "$TEST_ROOT/preexisting"
for sentinel in sentinel distribution-certificate.p12 profile.plist app.mobileprovision notification.mobileprovision; do
  printf 'keep' > "$TEST_ROOT/preexisting/$sentinel"
done
if render_configuration "$TEST_ROOT/preexisting" "46" "" >"$TEST_ROOT/preexisting.log" 2>&1; then
  echo "The renderer replaced a pre-existing output directory." >&2
  exit 1
fi
for sentinel in sentinel distribution-certificate.p12 profile.plist app.mobileprovision notification.mobileprovision; do
  [[ "$(cat "$TEST_ROOT/preexisting/$sentinel")" == "keep" ]]
done
grep -F "The TestFlight output directory already exists; refusing to replace it." "$TEST_ROOT/preexisting.log" >/dev/null

EXISTING_KEY_DIR="$TEST_ROOT/existing-key/private_keys"
EXISTING_KEY_PATH="$EXISTING_KEY_DIR/AuthKey_KEY1234567.p8"
mkdir -p "$(dirname "$EXISTING_KEY_PATH")"
printf 'pre-existing' > "$EXISTING_KEY_PATH"
# shellcheck disable=SC2016 # The child shell expands its sourced helper state.
bash -c '
  source "$1"
  ASC_KEY_DIR="$2"
  APP_STORE_CONNECT_API_KEY_ID="KEY1234567"
  APP_STORE_CONNECT_API_KEY="replacement"
  if prepare_app_store_connect_key; then
    echo "The helper replaced a pre-existing App Store Connect key." >&2
    exit 1
  fi
  cleanup
' _ "$ROOT_DIR/script/deploy_companion_testflight.sh" "$EXISTING_KEY_DIR" 2>"$TEST_ROOT/existing-key.log"
[[ "$(cat "$EXISTING_KEY_PATH")" == "pre-existing" ]]
grep -F "The App Store Connect key path already exists on the runner." "$TEST_ROOT/existing-key.log" >/dev/null

CREATED_KEY_DIR="$TEST_ROOT/created-key/private_keys"
mkdir -p "$(dirname "$CREATED_KEY_DIR")"
# shellcheck disable=SC2016 # The child shell expands its sourced helper state.
bash -c '
  source "$1"
  ASC_KEY_DIR="$2"
  APP_STORE_CONNECT_API_KEY_ID="KEY1234567"
  APP_STORE_CONNECT_API_KEY="temporary"
  prepare_app_store_connect_key
  [[ -f "$ASC_KEY_FILE" ]]
  created_key="$ASC_KEY_FILE"
  cleanup
  [[ ! -e "$created_key" ]] || {
    echo "The helper did not remove the App Store Connect key it created." >&2
    exit 1
  }
' _ "$ROOT_DIR/script/deploy_companion_testflight.sh" "$CREATED_KEY_DIR"

echo "TestFlight helper tests passed."
