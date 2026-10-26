#!/usr/bin/env bash
# Sourced by build_and_run.sh. Selection only: this never signs or imports a certificate.
myterm_select_signing_identity() {
  local distribution="$1"
  local identity="${CODESIGN_IDENTITY:-}"
  local available
  if [[ -z "$identity" ]]; then
    available="$(security find-identity -v -p codesigning 2>/dev/null)" || available=""
    if [[ "$distribution" != "1" ]]; then
      identity="$(awk -F '"' '/Apple Development/ {print $2; exit}' <<< "$available")"
    fi
    if [[ -z "$identity" ]]; then
      identity="$(awk -F '"' '/Developer ID Application/ {print $2; exit}' <<< "$available")"
    fi
  fi
  if [[ -z "$identity" ]]; then
    echo 'No suitable signing identity found. Install an Apple Development or Developer ID Application identity, or explicitly set CODESIGN_IDENTITY=- for an ad-hoc development bundle.' >&2
    return 1
  fi
  if [[ "$distribution" == "1" && "$identity" == "-" ]]; then
    echo 'Distribution bundling requires a Developer ID Application identity.' >&2
    return 1
  fi
  if [[ "$identity" == "-" ]]; then
    echo 'Ad-hoc signing was explicitly selected. Rebuilding changes the designated requirement; existing Keychain items may need one-time authorization under a stable signing identity.' >&2
  fi
  printf '%s\n' "$identity"
}
