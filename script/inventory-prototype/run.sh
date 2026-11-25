#!/bin/bash
set -euo pipefail
caller_dir="$PWD"
cd "$(dirname "$0")"
build_dir="${MYTERM_INVENTORY_BUILD_DIR:-/tmp/myterm-inventory-prototype-build}"
mkdir -p "$build_dir/MyTerm Inventory Prototype.app/Contents/MacOS"
binary="$build_dir/MyTerm Inventory Prototype.app/Contents/MacOS/InventoryPrototype"
swiftc -swift-version 6 Model.swift main.swift -o "$binary"
if [[ "${1:-}" == --verify ]]; then
  evidence_dir="${2:-$build_dir/evidence}"
  [[ "$evidence_dir" == /* ]] || evidence_dir="$caller_dir/$evidence_dir"
  "$binary" --verify "$evidence_dir"
else
  cat > "$build_dir/MyTerm Inventory Prototype.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InventoryPrototype</string>
<key>CFBundleIdentifier</key><string>com.gordonbeeming.myterm.inventory-prototype</string>
<key>CFBundleName</key><string>MyTerm Inventory Prototype</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  open -n "$build_dir/MyTerm Inventory Prototype.app"
fi
