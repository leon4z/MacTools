import AppKit
import IOKit

@MainActor final class RecoveryLease: HIDSettingsLeasing {
    var live = Set<String>(["old"])
    var cached = Set<String>(["old"])
    var values: [String: [[String: Any]]] = ["old": []]
    var unreadable = false
    var refreshes = 0
    var writes = 0
    let url: URL
    lazy var journal = PropertyLeaseJournal(url: url, bootID: "test",
        available: { self.cached }, read: { id, _ in self.live.contains(id) && !self.unreadable ? self.values[id] : nil },
        write: { id, _, value in
            guard self.live.contains(id) else { return false }
            self.writes += 1; self.values[id] = value as? [[String: Any]]; return true
        })
    init(_ url: URL) { self.url = url }
    func refreshServices() { refreshes += 1; cached = live }
    var keyboardServiceIDs: Set<String> { cached }
    var mouseServiceIDs: Set<String> { cached }
    var services: [IOHIDServiceClient] { [] }
    var mice: [IOHIDServiceClient] { [] }
    var keyboards: [IOHIDServiceClient] { [] }
    var ownershipState: PropertyLeaseOwnership { journal.ownershipState }
    func id(_ service: IOHIDServiceClient) -> String { fatalError("no real services") }
    func property(_ service: IOHIDServiceClient, _ key: String) -> Any? { fatalError("no real services") }
    func name(_ service: IOHIDServiceClient) -> String { fatalError("no real services") }
    func set(_ service: IOHIDServiceClient, key: String, value: Any, missingDefault: Any, force: Bool) throws { fatalError("no real services") }
    func recover() throws { try journal.recover() }
    func restore() throws { try journal.restore() }
}
@MainActor final class RecoveryCaps: CapsLockLeasing {
    let fixture: RecoveryLease
    var lease: any HIDSettingsLeasing { fixture }
    var failures = 0
    var attempts = 0
    init(_ lease: RecoveryLease) { fixture = lease }
    func enable() throws {
        attempts += 1
        if failures > 0 { failures -= 1; throw HIDFailure.message("device temporarily unavailable") }
        guard !fixture.cached.isEmpty else { throw HIDFailure.message("no keyboard") }
        for id in fixture.cached {
            let plan = try CapsLockMapping.replacingIdentity(in: fixture.values[id] ?? [])
            try fixture.journal.set(id: id, key: "UserKeyMapping", value: plan, missingDefault: [[String: Any]]())
        }
    }
}
@MainActor final class RecoveryListener: KeyboardEventListening {
    var starts = 0
    var active = false
    var failures = 0
    var handler: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
    func send(_ event: CGEvent) -> CGEvent? { handler?(event.type, event)?.takeUnretainedValue() }
    func start(_ handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool { starts += 1; if failures > 0 { failures -= 1; return false }; active = true; self.handler = handler; return true }
    func stop() { active = false; handler = nil }
}
@main enum InputRecoveryTests {
    @MainActor static func main() throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("local/test-build/recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyboard = RecoveryLease(dir.appendingPathComponent("keyboard.plist"))
        let pointer = RecoveryLease(dir.appendingPathComponent("pointer.plist"))
        let caps = RecoveryCaps(keyboard), listener = RecoveryListener()
        var time = 0.0
        var idle = true
        var trusted = true
        var heldKeys = Set<CGKeyCode>()
        var posted: [CGEvent] = []
        let runtime = InputRuntime(caps: caps, pointer: pointer, keyboardListener: listener, now: { time }, inputIdle: { idle }, keyIsDown: { heldKeys.contains($0) }, postEvent: { event, _ in posted.append(event) }, permission: { trusted }, runningApps: { [] })
        defer { runtime.stop() }
        var config = MacToolsConfiguration(); config.hyperEnabled = true
        config.hyper.meh.enabled = true; config.hyper.meh.trigger = .capsLock
        runtime.apply(config)
        precondition(runtime.hyperStatus.hasPrefix("映射已运行"), "baseline mapping must start")
        // Lock initiated with Meh held; its keyUp is consumed by the lock screen.
        let trigger = config.hyper.meh.trigger.keyCode
        heldKeys.insert(trigger)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: trigger, keyDown: true)!
        down.flags = []; _ = listener.send(down)
        runtime.markMappedCombinationUsed() // e.g. Meh+L locks screen
        heldKeys.remove(trigger) // released while input delivery is interrupted
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        click.flags = []
        let output = listener.send(click)!
        guard !output.flags.contains(.maskControl), !output.flags.contains(.maskAlternate), !output.flags.contains(.maskShift) else {
            print("FAIL: after lost lock-screen keyUp, plain left click carries Meh/Control flags: \(output.flags.rawValue)")
            exit(1)
        }
        precondition(posted.last?.flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty == true, "recovery releases synthetic modifiers")
        func triggerDown() {
            heldKeys.insert(trigger)
            let event = CGEvent(keyboardEventSource: nil, virtualKey: trigger, keyDown: true)!
            event.flags = []; _ = listener.send(event)
        }
        // Normal held mappings still apply; physical Ctrl must survive lost Meh release.
        triggerDown()
        let heldClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        heldClick.flags = []
        precondition(listener.send(heldClick)!.flags.contains([.maskControl, .maskAlternate, .maskShift]))
        heldKeys.remove(trigger); heldKeys.insert(59)
        let ctrlClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        ctrlClick.flags = [.maskControl, .maskAlternate, .maskShift]
        let ctrlOutput = listener.send(ctrlClick)!
        precondition(ctrlOutput.flags.contains(.maskControl) && !ctrlOutput.flags.contains(.maskAlternate) && !ctrlOutput.flags.contains(.maskShift))
        precondition(posted.last!.flags.contains(.maskControl), "real held Ctrl survives synthetic release")
        heldKeys.remove(59)
        // No mouse movement required: the health check releases a missed keyUp too.
        triggerDown(); heldKeys.remove(trigger)
        let beforeTimerRelease = posted.count
        time += 2; runtime.checkHealth()
        precondition(posted.count == beforeTimerRelease + 1)
        // Ordinary keyboard input, drag and scroll must not inherit stale Meh flags.
        for type: CGEventType in [.keyDown, .leftMouseDragged, .scrollWheel, .mouseMoved] {
            triggerDown(); heldKeys.remove(trigger)
            let event = CGEvent(source: nil)!; event.type = type
            event.setIntegerValueField(.keyboardEventKeycode, value: 0)
            event.flags = [.maskControl, .maskAlternate, .maskShift]
            precondition(listener.send(event)!.flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty)
        }
        // A real delivered keyUp still produces exactly one configured tap.
        var tapConfig = config; tapConfig.hyper.meh.tap = TapShortcut(keyCode: 53)
        runtime.apply(tapConfig)
        triggerDown(); heldKeys.remove(trigger)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: trigger, keyDown: false)!
        up.flags = []; _ = listener.send(up)
        let beforeTap = posted.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        precondition(posted.count == beforeTap + 2 && posted.suffix(2).allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 53 }, "delivered release must preserve tap")
        // Missing keyUp never executes a tap action, even when press was unused.
        triggerDown(); heldKeys.remove(trigger)
        let neutral = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        neutral.flags = []; _ = listener.send(neutral)
        let afterDiscard = posted.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        precondition(posted.count == afterDiscard, "recovered release cannot execute tap")
        runtime.apply(config)
        runtime.stop() // lock/sleep
        caps.failures = 1
        runtime.apply(config) // first wake attempt fails; device IDs remain unchanged
        precondition(!runtime.hyperStatus.hasPrefix("映射已运行"), "fixture must reproduce failed wake")
        for _ in 0..<8 { time += 2; runtime.checkHealth() }
        guard runtime.hyperStatus.hasPrefix("映射已运行") else {
            print("FAIL: failed wake remains paused without a process restart (attempts=\(caps.attempts))")
            exit(1)
        }
        precondition(keyboard.values["old"]?.contains { ($0["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value == CapsLockMapping.destination } == true)
        // Device generation changes: old snapshot -> empty wake -> new registry ID.
        keyboard.live = []; keyboard.values = [:]
        runtime.stop()
        precondition(keyboard.cached.isEmpty && keyboard.journal.pendingCount == 1, "stop refreshes stale client and preserves offline journal")
        runtime.apply(config)
        precondition(!runtime.hyperStatus.hasPrefix("映射已运行"))
        keyboard.live = ["new"]; keyboard.values = ["new": []]
        for _ in 0..<8 { time += 2; runtime.checkHealth() }
        precondition(runtime.hyperStatus.hasPrefix("映射已运行") && keyboard.cached == ["new"], "new device mapping recovers without replacing runtime")
        precondition(keyboard.journal.pendingCount == 2, "offline old record and live new lease coexist")
        precondition(keyboard.values["new"]?.contains { ($0["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value == CapsLockMapping.destination } == true)
        // A live service temporarily refusing reads blocks restore but retries later.
        keyboard.unreadable = true
        time += 2; runtime.checkHealth()
        precondition(!runtime.hyperStatus.hasPrefix("映射已运行"))
        keyboard.unreadable = false
        for _ in 0..<8 { time += 2; runtime.checkHealth() }
        guard runtime.hyperStatus.hasPrefix("映射已运行") else {
            print("FAIL: temporary unreadable ownership is mistaken for external takeover")
            exit(1)
        }
        runtime.stop()
        listener.failures = 1
        runtime.apply(config)
        precondition(!runtime.hyperStatus.hasPrefix("映射已运行"))
        for _ in 0..<8 { time += 2; runtime.checkHealth() }
        precondition(runtime.hyperStatus.hasPrefix("映射已运行"), "listener failure recovers on bounded retry")
        // Held physical keys defer recovery and do not consume the failure budget.
        runtime.stop(); idle = false
        let heldAttempts = caps.attempts
        runtime.apply(config)
        for _ in 0..<40 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts == heldAttempts && !listener.active)
        idle = true
        time += 2; runtime.checkHealth()
        precondition(runtime.hyperStatus.hasPrefix("映射已运行"), "release allows recovery without a restart")
        // Genuine external ownership is never retried, even if a mouse reconnects.
        let external: [[String: Any]] = [["HIDKeyboardModifierMappingSrc": NSNumber(value: CapsLockMapping.source), "HIDKeyboardModifierMappingDst": NSNumber(value: UInt64(0x700000004))]]
        keyboard.values["new"] = external
        time += 2; runtime.checkHealth()
        let externalAttempts = caps.attempts
        pointer.live = ["mouse-new"]
        for _ in 0..<40 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts == externalAttempts && PropertyLeaseJournal.equal(keyboard.values["new"]!, external), "mouse reconnect cannot clear keyboard ownership block")
        runtime.apply(config) // explicit recheck still respects a conflicting source.
        let conflictingAttempts = caps.attempts
        for _ in 0..<40 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts == conflictingAttempts && !listener.active)
        // Retries stop after five automatic attempts; manual apply grants a new budget.
        keyboard.values["new"] = []; caps.failures = 100
        let beforeBound = caps.attempts
        runtime.apply(config)
        for _ in 0..<100 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts - beforeBound == 6, "one initial attempt plus five bounded retries")
        precondition(runtime.hyperStatus.contains("请重新检查"))
        runtime.stop(); let stoppedAttempts = caps.attempts
        for _ in 0..<100 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts == stoppedAttempts, "lock/sleep/stop cancels retries")
        caps.failures = 0; runtime.apply(config)
        precondition(runtime.hyperStatus.hasPrefix("映射已运行"))
        trusted = false; time += 2; runtime.checkHealth()
        let permissionAttempts = caps.attempts
        trusted = true
        for _ in 0..<40 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts == permissionAttempts && !listener.active, "permission revocation stops retry until explicit recheck")
        runtime.apply(config)
        config.allEnabled = false; runtime.apply(config)
        let disabledAttempts = caps.attempts
        for _ in 0..<40 { time += 2; runtime.checkHealth() }
        precondition(caps.attempts == disabledAttempts && !listener.active, "user disable wins over recovery")
        print("InputRecoveryTests: wake failure, stale/empty/new devices, unreadable property, listener failure, held keys, external ownership, retry bounds and stop/permission/disable checks passed; no real HID or global input")
    }
}
