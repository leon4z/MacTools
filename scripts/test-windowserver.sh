#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p local/test-build
swiftc -target arm64-apple-macosx26.0 -import-objc-header Sources/App/HIDBridge.h -framework AppKit -framework IOKit \
  Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift \
  Sources/Vendor/LinearMouse/*.swift Sources/App/MouseScrollProcessor.swift Sources/App/MouseScrollRuntime.swift \
  Tests/MouseWindowServerTests.swift -o local/test-build/MouseWindowServerTests
APP="$PWD/local/test-build/MouseWindowServerTests.app"
mkdir -p "$APP/Contents/MacOS"
cp local/test-build/MouseWindowServerTests "$APP/Contents/MacOS/MouseWindowServerTests"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.leon4z.MacTools.ScrollTest</string>
<key>CFBundleExecutable</key><string>MouseWindowServerTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>MacTools Scroll Test</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
OUT="$PWD/local/test-build/windowserver.out"
ERR="$PWD/local/test-build/windowserver.err"
: > "$OUT"
: > "$ERR"
open -W -n --stdout "$OUT" --stderr "$ERR" "$APP"
cat "$OUT" "$ERR"
if /usr/bin/grep -q '^PASS:' "$OUT"; then exit 0; fi
if /usr/bin/grep -q '^SKIP:' "$OUT"; then exit 77; fi
exit 1
