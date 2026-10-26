#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=script/select_signing_identity.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select_signing_identity.sh"
# Mock the identity inventory. No Keychain calls, certificate access or signing occurs.
security() { printf '%s\n' "$TEST_IDENTITIES"; }
fail() { echo "$1" >&2; exit 1; }
unset CODESIGN_IDENTITY
TEST_IDENTITIES='1) AAA "Developer ID Application: Example"
2) BBB "Apple Development: Example"'
[[ "$(myterm_select_signing_identity 0)" == 'Apple Development: Example' ]] || fail 'Development should prefer Apple Development'
[[ "$(myterm_select_signing_identity 1)" == 'Developer ID Application: Example' ]] || fail 'Distribution should select Developer ID'
TEST_IDENTITIES='1) AAA "Developer ID Application: Example"'
[[ "$(myterm_select_signing_identity 0)" == 'Developer ID Application: Example' ]] || fail 'Development should fall back to Developer ID'
TEST_IDENTITIES='0 valid identities found'
if myterm_select_signing_identity 0 >/dev/null 2>&1; then fail 'Missing identity must not silently use ad-hoc'; fi
export CODESIGN_IDENTITY=-
[[ "$(myterm_select_signing_identity 0 2>/dev/null)" == '-' ]] || fail 'Explicit ad-hoc development should work'
if myterm_select_signing_identity 1 >/dev/null 2>&1; then fail 'Distribution must reject ad-hoc'; fi
export CODESIGN_IDENTITY='Explicit test identity'
[[ "$(myterm_select_signing_identity 0)" == "$CODESIGN_IDENTITY" ]] || fail 'Explicit identity should be preserved'
echo 'Signing identity selection tests passed (mocked inventory).'
