import AppKit
import Foundation

@MainActor private final class FakeRegistry: AppHotKeyRegistering {
    var actions: [() -> Void] = []
    var conflictCode: UInt16?
    func register(_ shortcut: TapShortcut, action: @escaping () -> Void) -> String? {
        if shortcut.keyCode == conflictCode { return "occupied" }
        actions.append(action); return nil
    }
    func unregisterAll() { actions.removeAll() }
}

@main enum AppShortcutTests {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("local/test-build/app-shortcut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("AppShortcuts.json")
        let empty = try AppShortcutStore.load(from: url); precondition(empty == AppShortcutConfiguration())
        var a = AppShortcut(name: "A", bundleIdentifier: "test.a", applicationPath: "/Applications/A.app")
        a.shortcut = TapShortcut(keyCode: 0, label: "Meh A", modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskShift]).rawValue)
        var b = AppShortcut(name: "B", bundleIdentifier: "test.b", applicationPath: "/Applications/B.app")
        b.shortcut = TapShortcut(keyCode: 1, label: "⌘S", modifiers: CGEventFlags.maskCommand.rawValue)
        var c = AppShortcutConfiguration(); c.enabled = true; c.apps = [a, b]
        try AppShortcutStore.save(c, to: url)
        let saved = try AppShortcutStore.load(from: url); precondition(saved == c)
        func rejects(_ value: AppShortcutConfiguration) {
            do { try value.validate(); preconditionFailure("invalid config accepted") } catch {}
        }
        var invalid = c; invalid.apps[1].shortcut = a.shortcut; rejects(invalid)
        invalid.apps[1].enabled = false; try invalid.validate()
        invalid = c; invalid.apps[0].shortcut.modifiers = CGEventFlags.maskShift.rawValue; rejects(invalid)
        invalid = c; invalid.apps[0].shortcut.keyCode = 79; rejects(invalid)
        invalid = c; invalid.apps[0].shortcut.modifiers |= 1; rejects(invalid)
        invalid = c; invalid.version = 2; rejects(invalid)
        invalid = c; invalid.apps[1].id = a.id; rejects(invalid)
        let registry = FakeRegistry()
        var missing: Set<UUID> = [b.id]
        var launches: [URL] = []
        var completions: [(String?) -> Void] = []
        let model = AppShortcutModel(registry: registry, storageURL: url,
            resolve: { missing.contains($0.id) ? nil : URL(fileURLWithPath: $0.applicationPath) },
            launch: { launches.append($0); completions.append($1) })
        precondition(registry.actions.isEmpty)
        model.setContext(allEnabled: true, inputRecording: false)
        precondition(registry.actions.count == 1 && model.issues[b.id] != nil)
        let stale = registry.actions[0]
        stale(); stale(); precondition(launches.count == 1, "in-flight launch deduplication")
        completions.removeFirst()(nil); stale(); precondition(launches.count == 2)
        model.setContext(allEnabled: false, inputRecording: false)
        stale(); precondition(registry.actions.isEmpty && launches.count == 2, "stale callbacks cannot run after disable")
        completions.removeFirst()("late error"); precondition(model.issues[a.id] == nil)
        missing = []; registry.conflictCode = 1
        model.setContext(allEnabled: true, inputRecording: false)
        precondition(registry.actions.count == 1 && model.issues[b.id] == "occupied")
        model.recording = true; precondition(registry.actions.isEmpty)
        model.recording = false; precondition(registry.actions.count == 1)
        model.setContext(allEnabled: true, inputRecording: true); precondition(registry.actions.isEmpty)
        model.setContext(allEnabled: true, inputRecording: false)
        let beforeStop = registry.actions[0]
        model.stop(); model.recording = false; beforeStop()
        precondition(registry.actions.isEmpty && launches.count == 2, "stop remains suspended until explicit resume")
        model.setContext(allEnabled: true, inputRecording: false)
        model.update { $0.enabled = false }; precondition(registry.actions.isEmpty)
        model.update { $0.apps[0].shortcut.keyCode = 79 }
        precondition(model.configuration.apps[0].shortcut.keyCode == 0 && model.errorMessage != nil, "invalid update retains good config")
        let retained = try AppShortcutStore.load(from: url); precondition(retained == model.configuration)
        model.update { $0.enabled = true }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        down.flags = CGEventFlags(rawValue: a.shortcut.modifiers)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        precondition(!model.handleMappedKey(.keyDown, down, mappingActive: false), "ordinary physical chords stay on Carbon")
        precondition(model.handleMappedKey(.keyDown, down, mappingActive: true))
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        precondition(model.handleMappedKey(.keyDown, down, mappingActive: true))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(launches.count == 3, "mapped chord launches once outside input callback")
        precondition(model.handleMappedKey(.keyUp, up, mappingActive: false), "release consumed even when trigger released first")
        precondition(!model.handleMappedKey(.keyUp, up, mappingActive: false))
        completions.removeFirst()(nil)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        precondition(model.handleMappedKey(.keyDown, down, mappingActive: true))
        model.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(launches.count == 3, "stop cancels queued mapped launch")
        precondition(!model.handleMappedKey(.keyDown, down, mappingActive: true))
        model.setContext(allEnabled: true, inputRecording: false)
        let conflict = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: true)!
        conflict.flags = .maskCommand
        precondition(!model.handleMappedKey(.keyDown, conflict, mappingActive: true), "mapped route respects Carbon conflict")
        model.recording = true
        precondition(!model.handleMappedKey(.keyDown, down, mappingActive: true), "recorder can receive mapped chords")
        model.recording = false
        precondition(model.handleMappedKey(.keyDown, down, mappingActive: true))
        model.recording = true
        precondition(model.handleMappedKey(.keyUp, up, mappingActive: false), "recording drains previously consumed key-up")
        model.recording = false
        precondition(model.handleMappedKey(.keyDown, down, mappingActive: true))
        model.update { $0.enabled = false }
        precondition(model.handleMappedKey(.keyUp, up, mappingActive: false), "module disable drains previously consumed key-up")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(launches.count == 3)
        precondition(AppHotKeyRegistry.carbonModifiers(CGEventFlags([.maskCommand, .maskAlternate, .maskControl, .maskShift]).rawValue) == 6912)
        // Thor behavior through the registered action: open -> hide -> reopen.
        try AppShortcutStore.save(c, to: url)
        let toggleRegistry = FakeRegistry()
        var front: String? = "test.previous"
        var previous: String?
        var hidden: [String] = []
        var toggleLaunches = 0
        var finishLaunch: ((String?) -> Void)?
        var hideSucceeds = true
        let toggler = AppShortcutModel(registry: toggleRegistry, storageURL: url,
            resolve: { URL(fileURLWithPath: $0.applicationPath) },
            frontmostBundleIdentifier: { front },
            hideFrontmost: { id in
                guard hideSucceeds else { return false }
                hidden.append(id); front = previous; return true
            }, launch: { _, completion in
                toggleLaunches += 1; previous = front; front = a.bundleIdentifier; finishLaunch = completion
            })
        toggler.setContext(allEnabled: true, inputRecording: false)
        let toggleAction = toggleRegistry.actions[0]
        toggleAction(); toggleAction()
        precondition(toggleLaunches == 1 && hidden.isEmpty, "opening in flight cannot immediately hide target")
        finishLaunch?(nil)
        toggleAction()
        precondition(front == "test.previous" && hidden == [a.bundleIdentifier] && toggleLaunches == 1)
        toggleAction(); finishLaunch?(nil)
        precondition(front == a.bundleIdentifier && toggleLaunches == 2, "third press reopens hidden target")
        hideSucceeds = false; toggleAction()
        precondition(toggler.issues[a.id] != nil && front == a.bundleIdentifier)
        hideSucceeds = true; toggleAction()
        precondition(toggler.issues[a.id] == nil && front == "test.previous")
        front = "test.other"; toggleAction(); finishLaunch?(nil); toggleAction()
        precondition(front == "test.other", "manual app changes use current OS ordering, not stale previous-app history")
        let hidesBeforeStop = hidden.count
        front = a.bundleIdentifier; toggler.stop(); toggleAction()
        precondition(hidden.count == hidesBeforeStop, "stale callback cannot hide after stop")
        toggler.activate(a); finishLaunch?(nil)
        precondition(hidden.count == hidesBeforeStop, "manual Open button remains open-only")
        toggleRegistry.conflictCode = 1
        toggler.setContext(allEnabled: true, inputRecording: false)
        toggler.activate(b); finishLaunch?(nil)
        precondition(toggler.issues[b.id] == "occupied", "manual open cannot clear registration conflicts")
        toggler.updateApp(b.id) { $0.shortcut = TapShortcut() }
        toggler.activate(b); finishLaunch?(nil)
        precondition(toggler.issues[b.id] == "尚未设置快捷键", "manual open cannot clear missing shortcut issue")
        // A failed read must never permit an update to erase the original file.
        let brokenURL = directory.appendingPathComponent("unreadable-configuration.json")
        let originalBytes = Data("invalid configuration preserved for recovery".utf8)
        try originalBytes.write(to: brokenURL)
        let blockedRegistry = FakeRegistry()
        let blocked = AppShortcutModel(registry: blockedRegistry, storageURL: brokenURL)
        precondition(!blocked.configurationLoaded)
        blocked.update { $0.enabled = true }
        let afterBlockedSave = try Data(contentsOf: brokenURL)
        precondition(afterBlockedSave == originalBytes)
        blocked.setContext(allEnabled: true, inputRecording: false)
        precondition(blockedRegistry.actions.isEmpty)
        try AppShortcutStore.save(c, to: brokenURL)
        blocked.reloadConfiguration()
        precondition(blocked.configurationLoaded && blocked.configuration == c && blocked.errorMessage == nil)
        print("AppShortcutTests: all tests passed (fake registry and launcher; no user settings or HID changes)")
    }
}
