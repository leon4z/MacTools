import AppKit
import ApplicationServices

private final class ScrollDocument: NSView { override var isFlipped: Bool { true } }

/// Opt-in integration test. Only posts wheel events into its own foreground
/// window, never changes HID parameters or persisted MacTools preferences.
@main enum MouseWindowServerTests {
    static func main() throws {
        guard AXIsProcessTrusted() else {
            print("SKIP: WindowServer test requires existing Accessibility permission; no permission prompt was requested.")
            exit(77)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 650, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MacTools 滚轮路由验证（自动关闭）"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 450))
        scroll.documentView = ScrollDocument(frame: NSRect(x: 0, y: 0, width: 5000, height: 5000))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.usesPredominantAxisScrolling = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
            }
        }
        pump(0.3)
        let runtime = MouseScrollRuntime()
        defer { runtime.stop(); window.orderOut(nil); previousApp?.activate() }
        guard NSApp.isActive else {
            print("SKIP: test window could not become active; no global wheel events posted.")
            return
        }
        func failure(_ message: String) -> NSError { NSError(domain: "MouseWindowServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        func postWheel() {
            let center = window.convertPoint(toScreen: NSPoint(x: 300, y: 200))
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0)!
            event.location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - center.y)
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        scroll.contentView.scroll(to: NSPoint(x: 1000, y: 1000)); pump(0.1)
        postWheel(); pump(0.4)
        let baseline = scroll.contentView.bounds.minY
        guard baseline < 1000 else { throw failure("raw WindowServer wheel failed: \(baseline)") }
        var preferences = MousePreferences(); preferences.reverseVertical = true
        guard runtime.start(preferences) else { throw failure("mouse event tap could not start") }
        scroll.contentView.scroll(to: NSPoint(x: 1000, y: 1000)); pump(0.1)
        postWheel(); pump(1.5)
        let reversed = scroll.contentView.bounds.minY
        runtime.stop()
        guard reversed > 1000 else { throw failure("reversed WindowServer wheel failed: \(reversed)") }
        scroll.contentView.scroll(to: NSPoint(x: 1000, y: 1000)); pump(0.1)
        postWheel(); pump(0.4)
        let stopped = scroll.contentView.bounds.minY
        guard stopped < 1000 else { throw failure("stop did not restore raw wheel: \(stopped)") }
        print("PASS: MouseWindowServerTests: baseline=\(baseline), reversed=\(reversed), stopped=\(stopped); all started at 1000")
    }
}
