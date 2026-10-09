#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 || ( $# -eq 3 && "$3" != "--repair" ) ]]; then
  echo "usage: $0 <app-bundle> <myterm-callback-scheme> [--repair]" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/myterm-callback-check.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
cat > "$TASK_TEMP/main.swift" <<'SWIFT'
import AppKit
import Foundation
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let scheme = CommandLine.arguments[2]
let repair = CommandLine.arguments.count == 4
Task { @MainActor in
    do {
        if repair { try await ApplicationCallbackRouting.prepare(applicationURL: app, scheme: scheme) }
        else { try ApplicationCallbackRouting.verify(applicationURL: app, scheme: scheme) }
        print("PASS: \(scheme) callback targets \(app.path)")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        if let url = URL(string: "\(scheme)://companion-auth/callback") {
            fputs("Current handler: \(NSWorkspace.shared.urlForApplication(toOpen: url)?.path ?? "none")\n", stderr)
        }
        exit(1)
    }
}
dispatchMain()
SWIFT
swiftc -target "$(uname -m)-apple-macos14.0" "$ROOT_DIR/Sources/MyTermPlatform/ApplicationCallbackRouting.swift" "$TASK_TEMP/main.swift" -o "$TASK_TEMP/check"
"$TASK_TEMP/check" "$@"
