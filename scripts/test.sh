#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$ROOT_DIR/local/test-build"
mkdir -p "$TEST_DIR"
cd "$ROOT_DIR"
run_test() {
    local name="$1"
    shift
    swiftc -target arm64-apple-macosx26.0 -framework AppKit -framework CryptoKit -framework CoreGraphics "$@" "Tests/$name.swift" -o "$TEST_DIR/$name"
    "$TEST_DIR/$name"
}
run_test AppMenuTests Sources/App/AppMenu.swift
run_test ToolConfigurationTests Sources/Shared/MoveRequest.swift Sources/Shared/ToolConfiguration.swift Sources/Shared/ToolCatalog.swift
run_test ToolMenuCacheTests Sources/Shared/ToolConfiguration.swift Sources/Shared/ToolCatalog.swift Sources/Extension/ToolMenuCache.swift
run_test MoveServiceTests Sources/Shared/ToolConfiguration.swift Sources/Shared/MoveRequest.swift Sources/App/MoveService.swift
run_test StandaloneMenuTests Sources/App/StandaloneMenuContext.swift
run_test InputPolicyTests Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/App/InputPolicies.swift
run_test TapShortcutEventsTests Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/Shared/ShortcutPresets.swift Sources/App/InputPolicies.swift Sources/App/TapShortcutEvents.swift
run_test AppShortcutTests -framework IOKit -framework Carbon Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/Shared/AppShortcutConfiguration.swift Sources/App/AppHotKeyRegistry.swift Sources/App/SystemShortcutExecutor.swift Sources/App/AppShortcutModel.swift Sources/App/ShortcutRecorder.swift
run_test PropertyLeaseTests Sources/App/PropertyLeaseJournal.swift
run_test InputRecoveryTests -import-objc-header Sources/App/HIDBridge.h -framework IOKit -framework Carbon Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/Shared/AppShortcutConfiguration.swift Sources/App/InputPolicies.swift Sources/App/NativeCapsLock.swift Sources/App/TapShortcutEvents.swift Sources/App/SystemShortcutExecutor.swift Sources/App/PropertyLeaseJournal.swift Sources/App/HIDSettingsLease.swift Sources/App/KeyboardEventListener.swift Sources/Vendor/LinearMouse/*.swift Sources/App/MouseScrollProcessor.swift Sources/App/MouseScrollRuntime.swift Sources/App/InputRuntime.swift
run_test CapsLockMappingTests -import-objc-header Sources/App/HIDBridge.h -framework IOKit Sources/App/PropertyLeaseJournal.swift Sources/App/HIDSettingsLease.swift
run_test MouseScrollProcessorTests -import-objc-header Sources/App/HIDBridge.h -framework IOKit Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/Vendor/LinearMouse/*.swift Sources/App/MouseScrollProcessor.swift Sources/App/MouseScrollRuntime.swift
run_test ShiftScrollTests -import-objc-header Sources/App/HIDBridge.h -framework IOKit Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/Vendor/LinearMouse/*.swift Sources/App/MouseScrollProcessor.swift
run_test WheelModifierTests -import-objc-header Sources/App/HIDBridge.h -framework IOKit Sources/Shared/ToolConfiguration.swift Sources/Shared/MacToolsConfiguration.swift Sources/Vendor/LinearMouse/*.swift Sources/App/MouseScrollProcessor.swift
run_test MouseEventThreadTests Sources/Vendor/LinearMouse/EventThread.swift
swiftc -target arm64-apple-macosx26.0 Sources/Vendor/LinearMouse/Compatibility.swift Sources/Vendor/LinearMouse/Bidirectional.swift Sources/Vendor/LinearMouse/Smoothed.swift Sources/Vendor/LinearMouse/SmoothedScrollingEngine.swift Tests/Upstream/CLTAssertions.swift Tests/Upstream/SmoothedScrollingEngineTests.swift Tests/Upstream/RunLinearMouseTests.swift -o "$TEST_DIR/LinearMouseUpstreamTests"
"$TEST_DIR/LinearMouseUpstreamTests"

SPARKLE_DIR="$(bash "$ROOT_DIR/scripts/setup-sparkle.sh")"
run_test AppUpdateTests -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR" Sources/App/AppUpdateModel.swift

run_test InputSessionLifecycleTests Sources/App/InputSessionLifecycle.swift
