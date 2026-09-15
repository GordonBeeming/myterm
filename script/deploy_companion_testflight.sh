#!/usr/bin/env bash
set -euo pipefail
umask 077

APP_BUNDLE_ID="com.gordonbeeming.myterm.companion"
NOTIFICATION_BUNDLE_ID="com.gordonbeeming.myterm.companion.notifications"
WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TASK_TEMP="${MYTERM_TESTFLIGHT_OUTPUT_DIR:-${RUNNER_TEMP:-/tmp}/myterm-testflight}"
CI_COMPANION="$TASK_TEMP/Companion"
CI_SPEC="$CI_COMPANION/project-ci.yml"
CI_PROJECT="$CI_COMPANION/MyTermCompanion.xcodeproj"
ARCHIVE_PATH="$TASK_TEMP/MyTermCompanion.xcarchive"
EXPORT_PATH="$TASK_TEMP/export"
EXPORT_OPTIONS="$TASK_TEMP/ExportOptions.plist"
KEYCHAIN_PATH="$TASK_TEMP/app-signing.keychain-db"
P12_PATH="$TASK_TEMP/distribution-certificate.p12"
P12_PEM_PATH="$TASK_TEMP/distribution-certificate.pem"
P12_IMPORT_PATH="$TASK_TEMP/distribution-import.p12"
PROFILE_PLIST="$TASK_TEMP/profile.plist"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
ASC_KEY_DIR="$HOME/.appstoreconnect/private_keys"
ASC_KEY_FILE=""
ASC_KEY_CREATED=false
ASC_KEY_DIR_CREATED=false
ASC_PARENT_DIR_CREATED=false
APP_PROFILE_DEST=""
NOTIFICATION_PROFILE_DEST=""
APP_PROFILE_SOURCE="$TASK_TEMP/app.mobileprovision"
NOTIFICATION_PROFILE_SOURCE="$TASK_TEMP/notification.mobileprovision"
KEYCHAIN_CREATED=false
TASK_TEMP_CREATED=false
ORIGINAL_KEYCHAINS=()

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required." >&2
    exit 2
  fi
}

require_single_line() {
  local name="$1" value="${!1:-}"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
    echo "$name must be a single-line value." >&2
    exit 2
  }
}

cleanup() {
  set +e
  [[ -n "$APP_PROFILE_DEST" ]] && rm -f "$APP_PROFILE_DEST"
  [[ -n "$NOTIFICATION_PROFILE_DEST" ]] && rm -f "$NOTIFICATION_PROFILE_DEST"
  [[ "$ASC_KEY_CREATED" == true && -n "$ASC_KEY_FILE" ]] && rm -f "$ASC_KEY_FILE"
  [[ "$ASC_KEY_DIR_CREATED" == true ]] && rmdir "$ASC_KEY_DIR" 2>/dev/null || true
  [[ "$ASC_PARENT_DIR_CREATED" == true ]] && rmdir "$(dirname "$ASC_KEY_DIR")" 2>/dev/null || true
  if [[ "$TASK_TEMP_CREATED" == true ]]; then
    rm -f "$P12_PATH" "$P12_PEM_PATH" "$P12_IMPORT_PATH" "$PROFILE_PLIST" "$APP_PROFILE_SOURCE" "$NOTIFICATION_PROFILE_SOURCE"
  fi
  if [[ "$KEYCHAIN_CREATED" == true && ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi
  if [[ "$KEYCHAIN_CREATED" == true && -f "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
}

ensure_safe_task_temp() {
  [[ "$TASK_TEMP" == /* && "$TASK_TEMP" != "/" && "$TASK_TEMP" != "$HOME" && "$TASK_TEMP" != "$WORKSPACE_ROOT" ]] || {
    echo "MYTERM_TESTFLIGHT_OUTPUT_DIR must be a dedicated absolute directory." >&2
    exit 2
  }
}

validate_public_configuration() {
  require_value APPLE_TEAM_ID
  require_value CODE_SIGN_IDENTITY
  require_value PROVISIONING_PROFILE_NAME
  require_value NOTIFICATION_PROVISIONING_PROFILE_NAME
  require_value APP_STORE_CONNECT_API_KEY_ID
  require_value APP_STORE_CONNECT_ISSUER_ID
  require_value BUILD_NUMBER
  require_single_line CODE_SIGN_IDENTITY
  require_single_line PROVISIONING_PROFILE_NAME
  require_single_line NOTIFICATION_PROVISIONING_PROFILE_NAME
  [[ "$APPLE_TEAM_ID" =~ ^[A-Za-z0-9]{10}$ ]] || {
    echo "APPLE_TEAM_ID must be a 10-character team identifier." >&2
    exit 2
  }
  [[ "$APP_STORE_CONNECT_API_KEY_ID" =~ ^[A-Za-z0-9]{10}$ ]] || {
    echo "APP_STORE_CONNECT_API_KEY_ID must be a 10-character key identifier." >&2
    exit 2
  }
  [[ "$APP_STORE_CONNECT_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo "APP_STORE_CONNECT_ISSUER_ID must be a UUID." >&2
    exit 2
  }
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "BUILD_NUMBER must be a positive integer." >&2
    exit 2
  }
  validate_optional_push_origin
}

validate_optional_push_origin() {
  local origin="${MYTERM_PUSH_GATEWAY_ORIGIN:-}"
  [[ -z "$origin" ]] && return
  if ! ruby -ruri -e '
    begin
      endpoint = URI.parse(ARGV.fetch(0))
      valid = endpoint.is_a?(URI::HTTPS) &&
        !endpoint.host.nil? && !endpoint.host.empty? &&
        endpoint.userinfo.nil? && endpoint.query.nil? && endpoint.fragment.nil? &&
        (endpoint.path.nil? || endpoint.path.empty? || endpoint.path == "/") &&
        endpoint.port.between?(1, 65_535)
      exit(valid ? 0 : 1)
    rescue URI::Error
      exit 1
    end
  ' "$origin"; then
    echo "MYTERM_PUSH_GATEWAY_ORIGIN must be empty or an HTTPS origin without credentials, a path, query, or fragment." >&2
    exit 2
  fi
}

render_ci_spec() {
  ditto "$WORKSPACE_ROOT/Companion" "$CI_COMPANION"
  ruby -ryaml - "$CI_COMPANION/project.yml" "$CI_SPEC" "$WORKSPACE_ROOT" <<'RUBY'
source, destination, root = ARGV
spec = YAML.load_file(source)
spec.fetch("packages").fetch("MyTerm")["path"] = root
spec.fetch("packages").fetch("MyTermRemote")["path"] = File.join(root, "Packages/MyTermRemote")
spec.fetch("packages").fetch("SwiftTerm")["path"] = File.join(root, "Vendor/SwiftTerm")
base = spec.fetch("settings").fetch("base")
base["DEVELOPMENT_TEAM"] = ENV.fetch("APPLE_TEAM_ID")
base["CODE_SIGN_STYLE"] = "Manual"
base["CODE_SIGN_IDENTITY"] = ENV.fetch("CODE_SIGN_IDENTITY")
base["MYTERM_PUSH_GATEWAY_ORIGIN"] = ENV.fetch("MYTERM_PUSH_GATEWAY_ORIGIN", "")
base["MYTERM_APP_PROVISIONING_PROFILE"] = ENV.fetch("PROVISIONING_PROFILE_NAME")
base["MYTERM_NOTIFICATION_PROVISIONING_PROFILE"] = ENV.fetch("NOTIFICATION_PROVISIONING_PROFILE_NAME")
File.write(destination, YAML.dump(spec))
RUBY
}

write_export_options() {
  TMPDIR="$TASK_TEMP" /usr/bin/python3 - "$EXPORT_OPTIONS" <<'PYTHON'
import os
import plistlib
import sys

document = {
    "method": "app-store-connect",
    "teamID": os.environ["APPLE_TEAM_ID"],
    "signingStyle": "manual",
    "signingCertificate": os.environ["CODE_SIGN_IDENTITY"],
    "provisioningProfiles": {
        "com.gordonbeeming.myterm.companion": os.environ["PROVISIONING_PROFILE_NAME"],
        "com.gordonbeeming.myterm.companion.notifications": os.environ["NOTIFICATION_PROVISIONING_PROFILE_NAME"],
    },
    "uploadSymbols": True,
}
with open(sys.argv[1], "wb") as stream:
    plistlib.dump(document, stream, fmt=plistlib.FMT_XML, sort_keys=False)
PYTHON
  plutil -lint "$EXPORT_OPTIONS" >/dev/null
}

install_profile() {
  local encoded="$1" expected_name="$2" expected_bundle="$3" source_path="$4"
  printf '%s' "$encoded" | base64 --decode > "$source_path"
  security cms -D -i "$source_path" > "$PROFILE_PLIST"
  local uuid name application_identifier destination
  uuid=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")
  name=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")
  application_identifier=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST")
  [[ "$name" == "$expected_name" ]] || {
    echo "Provisioning profile name does not match the configured profile name." >&2
    return 1
  }
  [[ "$application_identifier" == "$APPLE_TEAM_ID.$expected_bundle" ]] || {
    echo "Provisioning profile does not match $expected_bundle." >&2
    return 1
  }
  local provisions_all_devices=""
  provisions_all_devices=$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" 2>/dev/null || true)
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" >/dev/null 2>&1 || \
      [[ "$provisions_all_devices" == true || "$provisions_all_devices" == YES ]]; then
    echo "Provisioning profile for $expected_bundle is not an App Store distribution profile." >&2
    return 1
  fi
  [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo "Provisioning profile for $expected_bundle has an invalid UUID." >&2
    return 1
  }
  destination="$PROFILE_DIR/$uuid.mobileprovision"
  [[ ! -e "$destination" ]] || {
    echo "A provisioning profile with UUID $uuid is already installed on the runner." >&2
    return 1
  }
  mkdir -p "$PROFILE_DIR"
  cp "$source_path" "$destination"
  printf '%s' "$destination"
}

run_altool() {
  local action="$1" log_path
  case "$action" in
    --validate-app|--upload-app) ;;
    *) echo "Unsupported altool action." >&2; return 2 ;;
  esac
  log_path="$TASK_TEMP/altool_${action#--}.log"
  if ! xcrun altool "$action" -f "$IPA_PATH" -t ios \
      --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
      --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID" 2>&1 | tee "$log_path"; then
    echo "altool $action exited non-zero." >&2
    return 1
  fi
  if grep -qiE 'UPLOAD FAILED|VALIDATE FAILED|ERROR ITMS|\*\* ERROR|errorMessage' "$log_path"; then
    echo "altool $action reported an error." >&2
    return 1
  fi
}

prepare_app_store_connect_key() {
  local parent candidate
  parent=$(dirname "$ASC_KEY_DIR")
  candidate="$ASC_KEY_DIR/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
  [[ ! -e "$candidate" ]] || {
    echo "The App Store Connect key path already exists on the runner." >&2
    return 1
  }
  if [[ ! -d "$parent" ]]; then
    mkdir -m 700 "$parent"
    ASC_PARENT_DIR_CREATED=true
  fi
  if [[ ! -d "$ASC_KEY_DIR" ]]; then
    mkdir -m 700 "$ASC_KEY_DIR"
    ASC_KEY_DIR_CREATED=true
  fi
  ASC_KEY_FILE="$candidate"
  if ! (set -o noclobber; umask 177; printf '%s' "$APP_STORE_CONNECT_API_KEY" > "$ASC_KEY_FILE"); then
    ASC_KEY_FILE=""
    echo "The App Store Connect key path could not be created exclusively." >&2
    return 1
  fi
  ASC_KEY_CREATED=true
}

prepare_keychain_p12() {
  local -a read_options=()
  if openssl version | grep -q '^OpenSSL 3\.'; then
    read_options=(-legacy)
  fi
  # Keychain rejects OpenSSL 3's default PKCS#12 encryption/MAC format.
  # Keep the decoded key within the mode-700 task directory (umask 077).
  if ! openssl pkcs12 "${read_options[@]}" -in "$P12_PATH" -passin env:CERTIFICATES_PASSWORD \
      -nodes -out "$P12_PEM_PATH"; then
    rm -f "$P12_PEM_PATH"
    return 1
  fi
  if ! openssl pkcs12 -export -in "$P12_PEM_PATH" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      -passout env:CERTIFICATES_PASSWORD -out "$P12_IMPORT_PATH"; then
    rm -f "$P12_PEM_PATH" "$P12_IMPORT_PATH"
    return 1
  fi
  rm -f "$P12_PEM_PATH"
}

main() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ensure_safe_task_temp
  validate_public_configuration
  [[ ! -e "$TASK_TEMP" ]] || {
    echo "The TestFlight output directory already exists; refusing to replace it." >&2
    exit 2
  }
  mkdir -m 700 "$TASK_TEMP"
  TASK_TEMP_CREATED=true
  render_ci_spec
  write_export_options

  if [[ "${1:-}" == "--render-only" ]]; then
    ruby -ryaml - "$CI_SPEC" <<'RUBY'
spec = YAML.load_file(ARGV[0])
base = spec.fetch("settings").fetch("base")
abort unless base.fetch("MYTERM_APP_PROVISIONING_PROFILE") == ENV.fetch("PROVISIONING_PROFILE_NAME")
abort unless base.fetch("MYTERM_NOTIFICATION_PROVISIONING_PROFILE") == ENV.fetch("NOTIFICATION_PROVISIONING_PROFILE_NAME")
abort unless spec.dig("targets", "MyTermCompanion", "settings", "configs", "Release", "PROVISIONING_PROFILE_SPECIFIER") == "$(MYTERM_APP_PROVISIONING_PROFILE)"
abort unless spec.dig("targets", "MyTermNotificationService", "settings", "configs", "Release", "PROVISIONING_PROFILE_SPECIFIER") == "$(MYTERM_NOTIFICATION_PROVISIONING_PROFILE)"
RUBY
    echo "TestFlight signing configuration rendered successfully."
    exit 0
  fi

  require_value CERTIFICATES_P12
  require_value CERTIFICATES_PASSWORD
  require_value PROVISIONING_PROFILE
  require_value NOTIFICATION_PROVISIONING_PROFILE
  require_value APP_STORE_CONNECT_API_KEY
  command -v xcodegen >/dev/null || { echo "xcodegen is required." >&2; exit 1; }

  KEYCHAIN_PASSWORD=$(openssl rand -base64 32)
  while IFS= read -r line; do
    keychain="${line#"${line%%[![:space:]]*}"}"
    keychain="${keychain#\"}"
    keychain="${keychain%\"}"
    [[ -n "$keychain" ]] && ORIGINAL_KEYCHAINS+=("$keychain")
  done < <(security list-keychains -d user)
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  KEYCHAIN_CREATED=true
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  printf '%s' "$CERTIFICATES_P12" | base64 --decode > "$P12_PATH"
  prepare_keychain_p12
  security import "$P12_IMPORT_PATH" -k "$KEYCHAIN_PATH" -P "$CERTIFICATES_PASSWORD" -T /usr/bin/codesign
  security list-keychains -d user -s "$KEYCHAIN_PATH"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "$CODE_SIGN_IDENTITY" >/dev/null || {
    echo "The imported certificate does not contain $CODE_SIGN_IDENTITY." >&2
    exit 1
  }
  rm -f "$P12_PATH" "$P12_IMPORT_PATH"

  APP_PROFILE_DEST=$(install_profile "$PROVISIONING_PROFILE" "$PROVISIONING_PROFILE_NAME" \
    "$APP_BUNDLE_ID" "$APP_PROFILE_SOURCE")
  NOTIFICATION_PROFILE_DEST=$(install_profile "$NOTIFICATION_PROVISIONING_PROFILE" \
    "$NOTIFICATION_PROVISIONING_PROFILE_NAME" "$NOTIFICATION_BUNDLE_ID" \
    "$NOTIFICATION_PROFILE_SOURCE")

  xcodegen generate --spec "$CI_SPEC" --project "$CI_COMPANION" --project-root "$CI_COMPANION" --quiet

  xcodebuild archive \
    -project "$CI_PROJECT" \
    -scheme MyTermCompanion \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    MYTERM_APP_PROVISIONING_PROFILE="$PROVISIONING_PROFILE_NAME" \
    MYTERM_NOTIFICATION_PROVISIONING_PROFILE="$NOTIFICATION_PROVISIONING_PROFILE_NAME"

  [[ -d "$ARCHIVE_PATH" ]] || { echo "Archive was not created." >&2; exit 1; }
  codesign --verify --deep --strict --verbose=2 \
    "$ARCHIVE_PATH/Products/Applications/MyTermCompanion.app"

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

  IPA_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print)
  [[ -n "$IPA_PATH" && "$(printf '%s\n' "$IPA_PATH" | wc -l | tr -d ' ')" == "1" ]] || {
    echo "Expected exactly one exported IPA." >&2
    exit 1
  }

  prepare_app_store_connect_key

  run_altool --validate-app
  run_altool --upload-app

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'MYTERM_IPA_PATH=%s\n' "$IPA_PATH" >> "$GITHUB_ENV"
  fi
  echo "TestFlight upload completed for build $BUILD_NUMBER."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
