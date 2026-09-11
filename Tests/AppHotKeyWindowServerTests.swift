import AppKit
import ApplicationServices

/// Opt-in integration test. A real app hosts Carbon; a CLI process with existing
/// permission injects only the chord that app has successfully registered.
@main enum AppHotKeyWindowServerTests {
    static let marker: Int64 = 0x4D54524F5554
    static let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(77) }
        let mode = CommandLine.arguments[1]
        let state = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "post" { try post(state); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular); NSApp.finishLaunching()
        let registry = AppHotKeyRegistry()
        defer { registry.unregisterAll() }
        var count = 0
        if let error = registry.register(TapShortcut(keyCode: 106, label: "Meh F16", modifiers: flags.rawValue), action: {
            count += 1
            try? String(count).write(to: state.appendingPathComponent("count"), atomically: true, encoding: .utf8)
        }) {
            print("SKIP: test chord unavailable: \(error)"); exit(77)
        }
        try "ready".write(to: state.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(15)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if Date() >= deadline || FileManager.default.fileExists(atPath: state.appendingPathComponent("done").path) {
                NSApp.stop(nil)
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(wake, atStart: true) }
            }
        }
        NSApp.run(); timer.invalidate()
        print("Listener received \(count) presses")
    }
    static func post(_ state: URL) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { print("SKIP: poster needs existing input permission"); exit(77) }
        guard FileManager.default.fileExists(atPath: state.appendingPathComponent("ready").path) else { print("SKIP: listener not ready"); exit(77) }
        guard CGEventSource.flagsState(.hidSystemState).intersection(flags.union(.maskCommand)).isEmpty else { print("SKIP: physical modifiers held"); exit(77) }
        defer { try? "done".write(to: state.appendingPathComponent("done"), atomically: true, encoding: .utf8) }
        func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func pair(_ flags: CGEventFlags, marked: Bool) {
            let source = CGEventSource(stateID: .privateState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 106, keyDown: true)!
            let up = CGEvent(keyboardEventSource: source, virtualKey: 106, keyDown: false)!
            down.flags = flags; up.flags = flags
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: marked ? marker : 0x4D5454455354)
                event.post(tap: .cghidEventTap); pump(0.2)
            }
        }
        func count() -> Int { Int((try? String(contentsOf: state.appendingPathComponent("count"), encoding: .utf8)) ?? "0") ?? 0 }
        pair(flags, marked: false)
        guard count() == 1 else { print("SKIP: Carbon did not dispatch synthetic input on this host; physical shortcut verification required"); exit(77) }
        pair(flags, marked: false)
        guard count() == 2 else { print("FAIL: release/repress count=\(count())"); exit(1) }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, _, event, _ in
            if event.getIntegerValueField(.eventSourceUserData) == AppHotKeyWindowServerTests.marker && event.getIntegerValueField(.keyboardEventKeycode) == 106 { event.flags = AppHotKeyWindowServerTests.flags }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { print("SKIP: session tap unavailable"); exit(77) }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        defer { CFMachPortInvalidate(tap); CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        pair([], marked: true)
        guard count() == 3 else { print("FAIL: session-tap Meh -> Carbon count=\(count())"); exit(1) }
        print("PASS: direct Carbon, release/repress, and session-tap Meh -> Carbon dispatch")
    }
}
