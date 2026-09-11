#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p local/test-build
swiftc -target arm64-apple-macosx26.0 -framework AppKit -framework Carbon \
  Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift \
  Sources/App/AppHotKeyRegistry.swift Tests/AppHotKeyWindowServerTests.swift \
  -o local/test-build/AppHotKeyWindowServerTests
APP="$PWD/local/test-build/AppHotKeyWindowServerTests.app"
mkdir -p "$APP/Contents/MacOS"
cp local/test-build/AppHotKeyWindowServerTests "$APP/Contents/MacOS/AppHotKeyWindowServerTests"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.leon.MacTools.AppShortcutTest</string>
<key>CFBundleExecutable</key><string>AppHotKeyWindowServerTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>MacTools Shortcut Test</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
OUT="$PWD/local/test-build/app-shortcut-windowserver.out"
ERR="$PWD/local/test-build/app-shortcut-windowserver.err"
: > "$OUT"
: > "$ERR"
STATE="$PWD/local/test-build/app-shortcut-route-$(date +%s)"
mkdir -p "$STATE"
open -n --stdout "$OUT" --stderr "$ERR" "$APP" --args listen "$STATE"
for attempt in {1..50}; do
    if [ -f "$STATE/ready" ]; then break; fi
    sleep 0.1
done
local/test-build/AppHotKeyWindowServerTests post "$STATE"
