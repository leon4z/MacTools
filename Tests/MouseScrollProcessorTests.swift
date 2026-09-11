import AppKit

private final class Document: NSView { override var isFlipped: Bool { true } }
@main enum MouseScrollProcessorTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw NSError(domain: "MouseScrollProcessorTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wheel(_ x: Int32 = 0, _ y: Int32 = 3, pixel: Bool = false) -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: pixel ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 5000, height: 5000))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.usesPredominantAxisScrolling = false
        window.contentView = scroll
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        scroll.layoutSubtreeIfNeeded()
        var time = 10.0
        var posted: [CGEvent] = []
        var callback: (() -> Void)?
        var cancelled = false
        var p = MousePreferences(); p.reverseVertical = true
        let engine = MouseScrollProcessor(preferences: p, now: { time }, sink: { event in
            posted.append(event.copy()!)
            if let decoded = NSEvent(cgEvent: event) {
                scroll.scrollWheel(with: decoded)
            }
            return true
        }, schedule: { tick in callback = tick; return { cancelled = true } })
        scroll.contentView.scroll(to: NSPoint(x: 1000, y: 1000))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let baselineY = scroll.contentView.bounds.minY
        scroll.scrollWheel(with: NSEvent(cgEvent: wheel(0, -14, pixel: true))!)
        try check(scroll.contentView.bounds.minY > baselineY, "native receiver baseline is ready before testing processor output")
        scroll.contentView.scroll(to: NSPoint(x: 1000, y: 1000))
        let initialY = scroll.contentView.bounds.minY
        try check(engine.transform(wheel()) == nil, "smoothing consumes input only after timer initialization")
        for _ in 0..<600 { time += 1.0/120; callback?() }
        try check(!posted.isEmpty, "real CGEvents emitted")
        try check(posted.contains { $0.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) < 0 }, "reverse vertical emits negative pixels")
        try check(posted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == MouseScrollProcessor.marker }, "synthetic events marked")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try check(scroll.contentView.bounds.minY > initialY, "CGEvent → NSEvent → native NSScrollView moves in reversed direction")
        try check(cancelled, "timer stops after tail")
        try check(engine.transform(posted[0]) === posted[0], "synthetic output does not reenter smoothing")
        let native = wheel(0, 4, pixel: true)
        try check(engine.transform(native) === native && native.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) == 4, "native continuous/trackpad passes untouched")
        _ = engine.transform(wheel())
        let beforeStop = posted.count
        engine.deactivate()
        for _ in 0..<30 { time += 1.0/120; callback?() }
        try check(posted.count == beforeStop, "stop cannot emit queued wheel events")
        let noTimer = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in fatalError("must pass through") }, schedule: { _ in nil })
        let original = wheel()
        try check(noTimer.transform(original) === original && original.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3, "timer failure returns original reversed tick")
        try check(noTimer.bypassSmoothing, "timer failure switches to direct scrolling")
        let noAllocation = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in true }, schedule: { _ in {} }, eventFactory: { _, _ in nil })
        try check(noAllocation.transform(wheel()) != nil, "allocation failure cannot consume tick")
        p.smooth = false; p.reverseHorizontal = true; p.scrollSpeed = 0.1
        let direct = MouseScrollProcessor(preferences: p, sink: { _ in true }, schedule: { _ in nil })
        let diagonal = wheel(2, 3)
        try check(direct.transform(diagonal) === diagonal, "direct scrolling preserves event identity")
        try check(diagonal.getIntegerValueField(.scrollWheelEventDeltaAxis1) < 0 && diagonal.getIntegerValueField(.scrollWheelEventDeltaAxis2) < 0, "low-speed integer deltas retain both axes")
        p.smooth = true; p.reverseVertical = false; p.reverseHorizontal = true; p.scrollSpeed = 1
        var horizontal: [CGEvent] = []
        let xEngine = MouseScrollProcessor(preferences: p, now: { time }, sink: { horizontal.append($0.copy()!); return true }, schedule: { _ in {} })
        _ = xEngine.transform(wheel(3, 0))
        for _ in 0..<600 { time += 1.0/120; xEngine.tick() }
        try check(horizontal.contains { $0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) < 0 }, "horizontal reverse emits x pixels")
        try check(horizontal.allSatisfy { $0.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) == 0 }, "horizontal wheel never moves vertical axis")
        var attempts = 0
        let sinkFailure = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in attempts += 1; return attempts > 1 }, schedule: { _ in {} })
        _ = sinkFailure.transform(wheel())
        for _ in 0..<100 { time += 1.0/120; sinkFailure.tick() }
        try check(sinkFailure.bypassSmoothing && sinkFailure.fallbackEvents == 1, "sink failure flushes pending original and switches to passthrough")
        for type: CGEventType in [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            var replayed = 0
            let interrupted = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in replayed += 1; return true }, schedule: { _ in {} })
            _ = interrupted.transform(wheel())
            let interaction = CGEvent(source: nil)!; interaction.type = type
            _ = interrupted.transform(interaction)
            for _ in 0..<10 { time += 1.0/120; interrupted.tick() }
            try check(replayed == 1, "first-frame interruption replays original exactly once: \(type)")
        }
        var flagOutputs: [CGEventFlags] = []
        let changedFlags = MouseScrollProcessor(preferences: p, now: { time }, sink: { flagOutputs.append($0.flags); return true }, schedule: { _ in {} })
        let first = wheel(); first.flags = []
        let second = wheel(); second.flags = .maskShift
        _ = changedFlags.transform(first); _ = changedFlags.transform(second)
        for _ in 0..<600 { time += 1.0/120; changedFlags.tick() }
        try check(flagOutputs.contains([]) && flagOutputs.contains(.maskShift), "flag boundary delivers both original and new sequence")
        var overflowOutputs = 0
        let stalled = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in overflowOutputs += 1; return true }, schedule: { _ in {} })
        for _ in 0..<64 { _ = stalled.transform(wheel()) }
        try check(stalled.transform(wheel()) != nil && overflowOutputs == 64 && stalled.bypassSmoothing, "stalled output is bounded and restores passthrough")
        var suspendedOutputs = 0
        let suspended = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in suspendedOutputs += 1; return true }, schedule: { _ in {} })
        _ = suspended.transform(wheel()); suspended.suspend()
        for _ in 0..<30 { time += 1.0/120; suspended.tick() }
        try check(suspendedOutputs == 1 && suspended.bypassSmoothing, "tap failure replays pending tick and disables smoothing")
        var allocations = 0; var allocatedOutputs = 0
        let laterFailure = MouseScrollProcessor(preferences: p, now: { time }, sink: { _ in allocatedOutputs += 1; return true }, schedule: { _ in {} }, eventFactory: { _, _ in
            allocations += 1
            return allocations == 1 ? wheel(0, 0, pixel: true) : nil
        })
        _ = laterFailure.transform(wheel())
        try check(laterFailure.transform(wheel()) != nil && allocatedOutputs == 1, "later preflight failure replays old tick and passes new tick")
        for _ in 0..<30 { time += 1.0/120; laterFailure.tick() }
        try check(allocatedOutputs == 1, "later preflight failure leaves no delayed tail")
        print("MouseScrollProcessorTests: \(checks) checks passed; native AppKit scroll offset \(initialY) -> \(scroll.contentView.bounds.minY)")
        // Only our temporary test window was shown; no events posted globally.
    }
}
