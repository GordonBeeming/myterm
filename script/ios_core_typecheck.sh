#!/bin/bash
# MyTermCore and MyTermRemoteProtocol are shared with the companion app, so a macOS-only API reaching
# either of them must fail here. `swift build` and `swift test` only ever target the host, so nothing
# else in this repository notices until the iOS app target breaks.
#
# The deployment target has to match the .iOS() entry in Package.swift.
set -euo pipefail

cd "$(dirname "$0")/.."

target="arm64-apple-ios17.0"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# MyTermRemoteProtocol imports MyTermCore, so the module has to exist for iOS before it can be
# checked against it.
xcrun --sdk iphoneos swiftc \
    -emit-module \
    -target "$target" \
    -swift-version 6 \
    -module-name MyTermCore \
    -emit-module-path "$work/MyTermCore.swiftmodule" \
    Sources/MyTermCore/*.swift

xcrun --sdk iphoneos swiftc \
    -typecheck \
    -target "$target" \
    -swift-version 6 \
    -module-name MyTermRemoteProtocol \
    -I "$work" \
    Sources/MyTermRemoteProtocol/*.swift

echo "MyTermCore and MyTermRemoteProtocol type-check against the iOS SDK."
