#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MACTOOLS_BUILD_DIR:-$ROOT_DIR/build}"
# Alternate outputs stay inside this project; never clean an arbitrary path.
if [[ "$BUILD_DIR" != "$ROOT_DIR/build" && "$BUILD_DIR" != "$ROOT_DIR/local/"*"/build" ]] || [[ "$BUILD_DIR" == *"/../"* ]]; then
  echo "Unsupported build output directory" >&2
  exit 1
fi
APP="$BUILD_DIR/MacTools.app"
APPEX="$APP/Contents/PlugIns/MacToolsFinderExtension.appex"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"
SPARKLE_DIR="$(bash "$ROOT_DIR/scripts/setup-sparkle.sh")"
SIGNING_IDENTITY="${MACTOOLS_SIGNING_IDENTITY:--}"


rm -rf "$BUILD_DIR"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/PlugIns" \
  "$APPEX/Contents/MacOS" \
  "$APPEX/Contents/Resources"

cp "$ROOT_DIR/Sources/Vendor/LinearMouse/LICENSE" "$APP/Contents/Resources/LinearMouse-LICENSE.txt"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_DIR/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/Resources/AppInfo.plist" "$APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/ExtensionInfo.plist" "$APPEX/Contents/Info.plist"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

swiftc \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -module-name MacTools \
  -F "$SPARKLE_DIR" \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit \
  -framework CryptoKit \
  -framework FinderSync \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -framework ApplicationServices \
  -framework IOKit \
  -framework Carbon \
  -import-objc-header "$ROOT_DIR/Sources/App/HIDBridge.h" \
  "$ROOT_DIR/Sources/Shared/ToolConfiguration.swift" \
  "$ROOT_DIR/Sources/Shared/MacToolsConfiguration.swift" \
  "$ROOT_DIR/Sources/Shared/ToolCatalog.swift" \
  "$ROOT_DIR/Sources/Shared/MoveRequest.swift" \
  "$ROOT_DIR/Sources/App/MoveService.swift" \
  "$ROOT_DIR/Sources/App/MoveFeature.swift" \
  "$ROOT_DIR/Sources/App/AppMenu.swift" \
  "$ROOT_DIR/Sources/App/NewFileFeature.swift" \
  "$ROOT_DIR/Sources/App/SettingsFeature.swift" \
  "$ROOT_DIR/Sources/App/StandaloneMenuContext.swift" \
  "$ROOT_DIR/Sources/App/FinderAccessibilityContext.swift" \
  "$ROOT_DIR/Sources/App/StandaloneMenuController.swift" \
  "$ROOT_DIR/Sources/App/InputPolicies.swift" \
  "$ROOT_DIR/Sources/Shared/ShortcutPresets.swift" \
  "$ROOT_DIR/Sources/App/TapShortcutEvents.swift" \
  "$ROOT_DIR/Sources/App/NativeCapsLock.swift" \
  "$ROOT_DIR/Sources/App/PropertyLeaseJournal.swift" \
  "$ROOT_DIR/Sources/App/HIDSettingsLease.swift" \
  "$ROOT_DIR"/Sources/Vendor/LinearMouse/*.swift \
  "$ROOT_DIR/Sources/App/MouseScrollProcessor.swift" \
  "$ROOT_DIR/Sources/App/MouseScrollRuntime.swift" \
  "$ROOT_DIR/Sources/App/KeyboardEventListener.swift" \
  "$ROOT_DIR/Sources/App/InputRuntime.swift" \
  "$ROOT_DIR/Sources/Shared/AppShortcutConfiguration.swift" \
  "$ROOT_DIR/Sources/App/AppHotKeyRegistry.swift" \
  "$ROOT_DIR/Sources/App/SystemShortcutExecutor.swift" \
  "$ROOT_DIR/Sources/App/AppShortcutModel.swift" \
  "$ROOT_DIR/Sources/App/AppShortcutViews.swift" \
  "$ROOT_DIR/Sources/App/SharedConfigurationAccess.swift" \
  "$ROOT_DIR/Sources/App/AppUpdateModel.swift" \
  "$ROOT_DIR/Sources/App/InputSessionLifecycle.swift" \
  "$ROOT_DIR/Sources/App/MacToolsModel.swift" \
  "$ROOT_DIR/Sources/App/MacToolsViews.swift" \
  "$ROOT_DIR/Sources/App/ShortcutRecorder.swift" \
  "$ROOT_DIR/Sources/App/main.swift" \
  -o "$APP/Contents/MacOS/MacTools"

swiftc \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -module-name MacToolsFinderExtension \
  -framework AppKit \
  -framework FinderSync \
  "$ROOT_DIR/Sources/Shared/ToolConfiguration.swift" \
  "$ROOT_DIR/Sources/Shared/MacToolsConfiguration.swift" \
  "$ROOT_DIR/Sources/Shared/ToolCatalog.swift" \
  "$ROOT_DIR/Sources/Shared/MoveRequest.swift" \
  "$ROOT_DIR/Sources/Extension/ToolMenuCache.swift" \
  "$ROOT_DIR/Sources/Extension/FinderSync.swift" \
  "$ROOT_DIR/Sources/Extension/ExtensionMain.swift" \
  -o "$APPEX/Contents/MacOS/MacToolsFinderExtension"

# Sign inside-out. Never use --deep to sign nested code implicitly.
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for component in \
  "$SPARKLE_FRAMEWORK/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/XPCServices/Installer.xpc" \
  "$SPARKLE_FRAMEWORK/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Updater.app" \
  "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=entitlements "$component"
done
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT_DIR/Resources/Extension.entitlements" "$APPEX"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT_DIR/Resources/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
