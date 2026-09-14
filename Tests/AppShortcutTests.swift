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

@MainActor private final class FakeSystemExecutor: SystemShortcutExecuting {
    var availability: String?
    var failure: String?
    var executed: [SystemActionPlan] = []
    var deferred = false
    var completions: [(String?) -> Void] = []
    func plan(for item: SystemShortcut) throws -> SystemActionPlan {
        if let availability { throw AppShortcutError.message(availability) }
        return try SystemShortcutExecutor.makePlan(for: item)
    }
    func execute(_ plan: SystemActionPlan, completion: @escaping (String?) -> Void) {
        executed.append(plan)
        if deferred { completions.append(completion) } else { completion(failure) }
    }
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
        invalid = c; invalid.version = 3; rejects(invalid)
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

        // Published v1 application bindings upgrade without touching disk on load.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        legacy["version"] = 1; legacy.removeValue(forKey: "systemActions")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try legacyBytes.write(to: legacyURL)
        let upgraded = try AppShortcutStore.load(from: legacyURL)
        precondition(upgraded.version == 2 && upgraded.apps == c.apps && upgraded.enabled == c.enabled && upgraded.systemActions.isEmpty)
        let afterLegacyLoad = try Data(contentsOf: legacyURL)
        precondition(afterLegacyLoad == legacyBytes)
        legacy["version"] = 2 // A damaged v2 file must not silently lose system actions.
        do { _ = try JSONDecoder().decode(AppShortcutConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)); preconditionFailure("missing v2 actions accepted") } catch {}

        let mehL = TapShortcut(keyCode: 37, label: "⌃⌥⇧L", modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskShift]).rawValue)
        var lock = SystemShortcut(shortcut: mehL)
        var combined = c; combined.systemActions = [lock]
        try combined.validate()
        let systemURL = directory.appendingPathComponent("system.json")
        try AppShortcutStore.save(combined, to: systemURL)
        let roundTrip = try AppShortcutStore.load(from: systemURL)
        precondition(roundTrip == combined)
        var duplicate = combined; duplicate.systemActions[0].shortcut = a.shortcut; rejects(duplicate)
        duplicate.systemActions[0].enabled = false; try duplicate.validate()
        duplicate = combined; duplicate.systemActions.append(lock); rejects(duplicate)
        duplicate = combined; duplicate.systemActions[0].id = a.id; rejects(duplicate)
        duplicate = combined; duplicate.systemActions[0].shortcut.modifiers = CGEventFlags.maskShift.rawValue; rejects(duplicate)
        duplicate = combined; duplicate.systemActions[0].shortcut.keyCode = 79; rejects(duplicate)
        duplicate = combined; duplicate.systemActions[0].shortcut.modifiers |= 1; rejects(duplicate)
        lock.id = UUID(); duplicate = combined; duplicate.systemActions.append(lock); rejects(duplicate)
        var unknown = try JSONSerialization.jsonObject(with: JSONEncoder().encode(combined)) as! [String: Any]
        var actions = unknown["systemActions"] as! [[String: Any]]
        actions[0]["action"] = "unsupported"; unknown["systemActions"] = actions
        do { _ = try JSONDecoder().decode(AppShortcutConfiguration.self, from: JSONSerialization.data(withJSONObject: unknown)); preconditionFailure("unknown action accepted") } catch {}

        let systemRegistry = FakeRegistry(); let executor = FakeSystemExecutor()
        var systemMarked = 0
        let systemModel = AppShortcutModel(registry: systemRegistry, storageURL: systemURL, systemExecutor: executor,
            resolve: { URL(fileURLWithPath: $0.applicationPath) }, launch: { _, _ in preconditionFailure("system action opened app") })
        systemModel.onHotKeyActivation = { systemMarked += 1 }
        systemModel.setContext(allEnabled: true, inputRecording: false)
        precondition(systemRegistry.actions.count == 3)
        systemRegistry.actions.last!()
        let expectedLockPlan = try SystemShortcutExecutor.makePlan(for: combined.systemActions[0])
        precondition(executor.executed == [expectedLockPlan] && systemMarked == 1)
        let queuedBeforeDisable = systemRegistry.actions.last!
        systemModel.update { $0.enabled = false }; queuedBeforeDisable()
        precondition(executor.executed.count == 1 && systemRegistry.actions.isEmpty)
        systemModel.update { $0.enabled = true }
        let lockDown = CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true)!
        lockDown.flags = CGEventFlags(rawValue: mehL.modifiers)
        let lockUp = CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: false)!
        precondition(systemModel.handleMappedKey(.keyDown, lockDown, mappingActive: true))
        precondition(systemModel.handleMappedKey(.keyDown, lockDown, mappingActive: true))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(executor.executed.count == 2 && systemMarked == 2, "held mapped key fires once")
        precondition(systemModel.handleMappedKey(.keyUp, lockUp, mappingActive: false))
        precondition(systemModel.handleMappedKey(.keyDown, lockDown, mappingActive: true))
        systemModel.recording = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(executor.executed.count == 2, "recording cancels a queued lock")
        precondition(systemModel.handleMappedKey(.keyUp, lockUp, mappingActive: false))
        systemModel.recording = false
        let beforeSystemStop = systemRegistry.actions.last!
        systemModel.stop(); beforeSystemStop()
        precondition(executor.executed.count == 2)
        executor.availability = "permission missing"
        systemModel.setContext(allEnabled: true, inputRecording: false)
        precondition(systemRegistry.actions.count == 2 && systemModel.issues[combined.systemActions[0].id] == "permission missing")
        executor.availability = nil; systemRegistry.conflictCode = 37
        systemModel.setContext(allEnabled: true, inputRecording: false)
        precondition(systemRegistry.actions.count == 2 && !systemModel.handleMappedKey(.keyDown, lockDown, mappingActive: true))
        systemRegistry.conflictCode = nil; executor.failure = "dispatch failed"
        systemModel.setContext(allEnabled: true, inputRecording: false)
        systemRegistry.actions.last!()
        precondition(systemModel.issues[combined.systemActions[0].id] == "dispatch failed")
        systemModel.updateSystemAction(combined.systemActions[0].id) { $0.enabled = false }
        precondition(systemRegistry.actions.count == 2)
        let lockCommand = TapShortcut(keyCode: 12, label: "⌃⌘Q", modifiers: CGEventFlags([.maskControl, .maskCommand]).rawValue)
        precondition(AppHotKeyRegistry().register(lockCommand, action: { preconditionFailure() }) != nil, "native lock command cannot recursively bind")

        // Construct only; never post or lock the test machine.
        let restoreFlags: CGEventFlags = [.maskAlternate, .maskShift, .maskAlphaShift]
        let lockEvents = SystemShortcutExecutor.lockEvents(restoring: restoreFlags)
        precondition(lockEvents.count == 3)
        precondition(lockEvents[0].type == .keyDown && lockEvents[1].type == .keyUp && lockEvents[2].type == .flagsChanged)
        for event in lockEvents.prefix(2) {
            precondition(event.getIntegerValueField(.keyboardEventKeycode) == 12 && event.flags == [.maskControl, .maskCommand], "Meh modifiers cannot pollute lock command")
        }
        precondition(lockEvents[2].flags == restoreFlags)
        precondition(lockEvents.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SystemShortcutExecutor.eventMarker })

        // Every action has an explicit route. Only construct events; never dispatch
        // screenshots, media, input-source changes, display sleep or system sleep.
        let command = CGEventFlags.maskCommand.rawValue
        let control = CGEventFlags.maskControl.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        let keyRoutes: [(SystemShortcutAction, UInt16, UInt64)] = [
            (.lockScreen, 12, control | command), (.screenshotRegion, 21, command | shift),
            (.screenshotFull, 20, command | shift), (.showDesktop, 103, 0),
            (.previousSpace, 123, control), (.nextSpace, 124, control),
            (.toggleFullScreen, 3, control | command), (.emojiPicker, 49, control | command)
        ]
        for (action, key, modifiers) in keyRoutes {
            let plan = try SystemShortcutExecutor.makePlan(for: SystemShortcut(action: action))
            guard case .keyboard(let output) = plan else { preconditionFailure("wrong keyboard route") }
            precondition(output.keyCode == key && output.modifiers == modifiers)
            let events = SystemShortcutExecutor.keyboardEvents(output, restoring: restoreFlags)
            precondition(events.count == 3 && events[0].type == .keyDown && events[1].type == .keyUp)
            precondition(events.prefix(2).allSatisfy { $0.flags.rawValue == modifiers && $0.getIntegerValueField(.keyboardEventKeycode) == Int64(key) })
            precondition(events[2].type == .flagsChanged && events[2].flags == restoreFlags)
            precondition(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SystemShortcutExecutor.eventMarker })
        }
        let mediaRoutes: [(SystemShortcutAction, Int)] = [(.volumeUp, 0), (.volumeDown, 1), (.mute, 7),
            (.brightnessUp, 2), (.brightnessDown, 3), (.playPause, 16), (.nextTrack, 17), (.previousTrack, 18)]
        for (action, code) in mediaRoutes {
            let plan = try SystemShortcutExecutor.makePlan(for: SystemShortcut(action: action))
            precondition(plan == .mediaKey(code))
            let events = SystemShortcutExecutor.mediaEvents(code, restoring: restoreFlags)
            precondition(events.count == 3)
            for (index, state) in [0xA00, 0xB00].enumerated() {
                let event = NSEvent(cgEvent: events[index])!
                precondition(event.type == .systemDefined && event.subtype.rawValue == 8)
                precondition(event.data1 == (code << 16) | state && event.data2 == -1)
                precondition(event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty, "held Meh cannot pollute media keys")
            }
            precondition(events[2].flags == restoreFlags)
            precondition(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SystemShortcutExecutor.eventMarker })
        }
        let otherRoutes: [(SystemShortcutAction, SystemActionPlan)] = [
            (.screenshotToolbar, .openApplication("com.apple.screenshot.launcher")),
            (.missionControl, .openApplication("com.apple.exposelauncher")),
            (.spotlight, .openApplication("com.apple.Spotlight")),
            (.switchInputSource, .switchInputSource), (.displaySleep, .displaySleep), (.systemSleep, .systemSleep)]
        for (action, expected) in otherRoutes {
            let plan = try SystemShortcutExecutor.makePlan(for: SystemShortcut(action: action))
            precondition(plan == expected && plan.outputShortcut == nil)
        }
        precondition(keyRoutes.count + mediaRoutes.count + otherRoutes.count + 1 == SystemShortcutAction.allCases.count)

        // Custom outputs retain old v2 lock-only files and fail closed on cycles.
        var custom = SystemShortcut(action: .sendShortcut, shortcut: mehL)
        do { _ = try SystemShortcutExecutor.makePlan(for: custom); preconditionFailure("empty output accepted") } catch {}
        custom.targetShortcut = TapShortcut(keyCode: 8, label: "⌘C", modifiers: command)
        let customPlan = try SystemShortcutExecutor.makePlan(for: custom)
        precondition(customPlan == .keyboard(custom.targetShortcut!))
        var customConfig = c; customConfig.systemActions = [custom]
        try customConfig.validate()
        let customDecoded = try JSONDecoder().decode(AppShortcutConfiguration.self, from: JSONEncoder().encode(customConfig))
        precondition(customDecoded == customConfig)
        customConfig.systemActions[0].targetShortcut = mehL; rejects(customConfig)
        customConfig.systemActions[0].targetShortcut = a.shortcut; rejects(customConfig)
        customConfig.apps[0].enabled = false; try customConfig.validate()
        customConfig = c; customConfig.systemActions = [custom]
        for code: UInt16 in [54, 57, 63, 79, 128] {
            customConfig.systemActions[0].targetShortcut?.keyCode = code; rejects(customConfig)
        }
        customConfig.systemActions[0].targetShortcut = TapShortcut(keyCode: 49, label: "Space", modifiers: 0)
        try customConfig.validate() // Bare ordinary output keys are allowed.
        customConfig.systemActions[0].targetShortcut?.modifiers = 1; rejects(customConfig)
        var allActions = AppShortcutConfiguration()
        allActions.systemActions = SystemShortcutAction.allCases.map { SystemShortcut(action: $0) }
        try allActions.validate()
        let allDecoded = try JSONDecoder().decode(AppShortcutConfiguration.self, from: JSONEncoder().encode(allActions))
        precondition(allDecoded == allActions)

        // A built-in output must not activate another registered MacTools binding.
        var builtInCollision = combined
        builtInCollision.apps[0].shortcut = TapShortcut(keyCode: 3, label: "⌃⌘F", modifiers: command | control)
        builtInCollision.systemActions[0].action = .toggleFullScreen
        try AppShortcutStore.save(builtInCollision, to: systemURL)
        let routeRegistry = FakeRegistry(); let routeExecutor = FakeSystemExecutor()
        let routeModel = AppShortcutModel(registry: routeRegistry, storageURL: systemURL, systemExecutor: routeExecutor,
            resolve: { URL(fileURLWithPath: $0.applicationPath) }, launch: { _, _ in })
        routeModel.setContext(allEnabled: true, inputRecording: false)
        precondition(routeRegistry.actions.count == 2 && routeModel.issues[builtInCollision.systemActions[0].id] != nil)
        routeModel.updateApp(builtInCollision.apps[0].id) { $0.enabled = false }
        precondition(routeRegistry.actions.count == 2 && routeModel.issues[builtInCollision.systemActions[0].id] == nil)
        routeExecutor.deferred = true
        let asyncAction = routeRegistry.actions.last!
        asyncAction(); asyncAction()
        precondition(routeExecutor.executed.count == 1 && routeExecutor.completions.count == 1, "deduplicate asynchronous system requests")
        routeExecutor.completions.removeFirst()("request rejected")
        precondition(routeModel.issues[builtInCollision.systemActions[0].id] == "request rejected")
        asyncAction()
        precondition(routeExecutor.executed.count == 2)
        routeModel.stop()
        routeExecutor.completions.removeFirst()("stale error")
        precondition(routeModel.issues[builtInCollision.systemActions[0].id] != "stale error")
        routeExecutor.availability = "permission revoked"
        routeModel.setContext(allEnabled: true, inputRecording: false)
        precondition(routeRegistry.actions.count == 1)
        routeExecutor.availability = nil
        routeModel.setContext(allEnabled: true, inputRecording: false)
        let beforeRevoke = routeRegistry.actions.last!
        routeExecutor.availability = "permission revoked"; beforeRevoke()
        precondition(routeExecutor.executed.count == 2 && routeModel.issues[builtInCollision.systemActions[0].id] == "permission revoked", "recheck availability at invocation")

        // A recorder must not arm a newly chosen lock action while its key is held.
        let recorder = RecorderField()
        var recordings: [TapShortcut] = []
        recorder.onFocus = { systemModel.recording = $0 }
        recorder.onRecord = { recordings.append($0); systemModel.recording = false }
        func recordedEvent(_ type: NSEvent.EventType, code: UInt16 = 37, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 0,
                windowNumber: 0, context: nil, characters: "L", charactersIgnoringModifiers: "l", isARepeat: repeatKey, keyCode: code)!
        }
        precondition(recorder.becomeFirstResponder())
        recorder.keyDown(with: recordedEvent(.keyDown))
        recorder.keyDown(with: recordedEvent(.keyDown, repeatKey: true))
        precondition(recordings.isEmpty && systemModel.recording && systemRegistry.actions.isEmpty)
        recorder.keyUp(with: recordedEvent(.keyUp, code: 0))
        precondition(recordings.isEmpty && systemModel.recording, "unrelated key-up cannot finish")
        recorder.keyUp(with: recordedEvent(.keyUp))
        precondition(recordings == [mehL] && !systemModel.recording)
        _ = recorder.becomeFirstResponder()
        recorder.keyDown(with: recordedEvent(.keyDown))
        _ = recorder.resignFirstResponder()
        recorder.keyUp(with: recordedEvent(.keyUp))
        precondition(recordings.count == 1, "focus loss cancels pending chord")
        _ = recorder.becomeFirstResponder()
        recorder.keyDown(with: recordedEvent(.keyDown))
        ShortcutRecorder.dismantleNSView(recorder, coordinator: ())
        recorder.keyUp(with: recordedEvent(.keyUp))
        precondition(recordings.count == 1 && !systemModel.recording, "leaving a page cancels pending chord")
        print("AppShortcutTests: all tests passed (fake registry, launcher and system executor; no user settings, posted input or screen lock)")
    }
}
