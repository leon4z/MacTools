import AppKit

@main enum ShiftScrollTests {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ShiftScrollTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wheel(x: Int32 = 0, y: Int32 = 3, flags: CGEventFlags = [], pixel: Bool = false) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: pixel ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
        event.flags = flags; return event
    }
    static func run(x: Int32, y: Int32, flags: CGEventFlags, reverseX: Bool = false, reverseY: Bool = false) -> ([CGEvent], Int) {
        var time = 1.0
        var output: [CGEvent] = []
        var preferences = MousePreferences(); preferences.reverseHorizontal = reverseX; preferences.reverseVertical = reverseY
        let processor = MouseScrollProcessor(preferences: preferences, now: { time }, sink: { output.append($0.copy()!); return true }, schedule: { _ in {} })
        for frame in 0..<600 {
            if [0, 3, 6].contains(frame) { _ = processor.transform(wheel(x: x, y: y, flags: flags)) }
            time += 1.0 / 120; processor.tick()
        }
        return (output, processor.fallbackEvents)
    }
    static func total(_ events: [CGEvent], _ axis: CGEventField) -> Double {
        events.reduce(0) { $0 + $1.getDoubleValueField(axis) }
    }
    static func main() throws {
        let shifted = run(x: 0, y: 3, flags: .maskShift)
        let horizontal = run(x: 3, y: 0, flags: [])
        let vertical = run(x: 0, y: 3, flags: [])
        let x = CGEventField.scrollWheelEventPointDeltaAxis2, y = CGEventField.scrollWheelEventPointDeltaAxis1
        print("Shift+wheel emitted x=\(total(shifted.0, x)) y=\(total(shifted.0, y)); horizontal reference x=\(total(horizontal.0, x))")
        try require(!shifted.0.isEmpty && shifted.0.allSatisfy { $0.getDoubleValueField(y) == 0 }, "Shift+wheel emits vertical motion instead of horizontal-only output")
        try require(shifted.0.allSatisfy { !$0.flags.contains(.maskShift) }, "handled Shift must not reach receiver and reinterpret axes")
        try require(total(shifted.0, x) == total(horizontal.0, x) && total(horizontal.0, x) == total(vertical.0, y), "axis conversion must preserve total travel")
        try require(shifted.1 == 0 && shifted.0.count == horizontal.0.count, "holding Shift cannot restart smoothing on every tick")
        let alreadyHorizontal = run(x: 3, y: 0, flags: .maskShift)
        try require(total(alreadyHorizontal.0, x) == total(horizontal.0, x) && total(alreadyHorizontal.0, y) == 0, "an already-horizontal event must not swap back to vertical")
        let reversed = run(x: 0, y: 3, flags: .maskShift, reverseY: true)
        try require(total(reversed.0, x) == -total(horizontal.0, x), "Shift wheel follows its original vertical direction preference")
        let hardwareX = run(x: 3, y: 0, flags: .maskShift, reverseX: true)
        try require(total(hardwareX.0, x) == -total(horizontal.0, x), "hardware horizontal input retains horizontal reversal")
        let otherModifiers: CGEventFlags = [.maskShift, .maskControl]
        let passthrough = MouseScrollProcessor(preferences: MousePreferences(), sink: { _ in fatalError("application gesture must not be synthesized") }, schedule: { _ in nil })
        let controlShift = wheel(flags: otherModifiers)
        try require(passthrough.transform(controlShift) === controlShift && controlShift.flags == otherModifiers && controlShift.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3, "multiple modifier gestures remain owned by the application")
        let deviceShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x6 | CGEventFlags.maskAlphaShift.rawValue)
        let capsShift = run(x: 0, y: 3, flags: deviceShift)
        try require(capsShift.0.allSatisfy { $0.flags.rawValue == CGEventFlags.maskAlphaShift.rawValue }, "strip left/right Shift device bits but preserve Caps Lock")

        // A Shift release before the first frame must not replay vertical input.
        var time = 1.0; var output: [CGEvent] = []
        let processor = MouseScrollProcessor(preferences: MousePreferences(), now: { time }, sink: { output.append($0.copy()!); return true }, schedule: { _ in {} })
        _ = processor.transform(wheel(flags: .maskShift))
        let release = CGEvent(source: nil)!; release.type = .flagsChanged; release.flags = []
        _ = processor.transform(release)
        for _ in 0..<100 { time += 1.0/120; processor.tick() }
        try require(output.count == 1 && output[0].getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3 && output[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0 && !output[0].flags.contains(.maskShift), "release flushes one normalized horizontal tick, with no stale vertical tail")
        output.removeAll()
        _ = processor.transform(wheel())
        for _ in 0..<600 { time += 1.0/120; processor.tick() }
        try require(total(output, x) == 0 && total(output, y) != 0, "vertical scrolling resumes after release")

        // Modifier changes must also be detected from wheel events alone.
        var boundaryOutput: [CGEvent] = []
        let boundary = MouseScrollProcessor(preferences: MousePreferences(), now: { time }, sink: { boundaryOutput.append($0.copy()!); return true }, schedule: { _ in {} })
        _ = boundary.transform(wheel())
        _ = boundary.transform(wheel(flags: .maskShift))
        try require(boundaryOutput.count == 1 && boundaryOutput[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3 && boundaryOutput[0].getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0, "wheel-only Shift transition flushes the preceding unrendered vertical tick")
        boundaryOutput.removeAll()
        _ = boundary.transform(wheel())
        try require(boundaryOutput.count == 1 && boundaryOutput[0].getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3 && boundaryOutput[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0 && !boundaryOutput[0].flags.contains(.maskShift), "wheel-only Shift release flushes the preceding normalized horizontal tick")
        boundaryOutput.removeAll()
        for _ in 0..<600 { time += 1.0/120; boundary.tick() }
        try require(total(boundaryOutput, x) == 0 && total(boundaryOutput, y) != 0, "wheel-only transition resumes vertical output")

        // Fallback must agree with normal output, including every delta encoding.
        let noTimer = MouseScrollProcessor(preferences: MousePreferences(), sink: { _ in false }, schedule: { _ in nil })
        let original = wheel(flags: .maskShift)
        let originalView = ScrollWheelEventView(original)
        let oldLine = originalView.deltaY, oldPoint = originalView.deltaYPt, oldFixed = originalView.deltaYFixedPt
        let fallback = noTimer.transform(original)!
        let fallbackView = ScrollWheelEventView(fallback)
        try require(fallbackView.deltaX == oldLine && fallbackView.deltaXPt == oldPoint && fallbackView.deltaXFixedPt == oldFixed && fallbackView.deltaY == 0 && fallbackView.deltaYPt == 0 && fallbackView.deltaYFixedPt == 0, "fallback swaps all line, point and fixed delta fields consistently")

        // User-proven working direct path and native trackpad input stay untouched.
        var directPreferences = MousePreferences(); directPreferences.smooth = false
        let direct = MouseScrollProcessor(preferences: directPreferences, sink: { _ in false }, schedule: { _ in nil })
        let directEvent = wheel(flags: .maskShift)
        try require(direct.transform(directEvent) === directEvent && !directEvent.flags.contains(.maskShift) && directEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3, "configured Shift action also works without smoothing")
        let native = wheel(flags: .maskShift, pixel: true)
        try require(processor.transform(native) === native && native.flags.contains(.maskShift) && native.getDoubleValueField(y) == 3, "native continuous input remains untouched")
        print("ShiftScrollTests: all checks passed (event construction only, no global input)")
    }
}
