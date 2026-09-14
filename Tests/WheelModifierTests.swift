import AppKit

@main enum WheelModifierTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw NSError(domain: "WheelModifierTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static let flags: [CGEventFlags] = [.maskShift, .maskCommand, .maskAlternate, .maskControl]
    static let masks: [UInt64] = [0x6, 0x18, 0x60, 0x2001]
    static func wheel(_ flags: CGEventFlags = [], x: Int32 = 0, y: Int32 = 3, pixel: Bool = false) -> CGEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: pixel ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
        e.flags = flags; return e
    }
    static func main() throws {
        // Old files gain defaults without discarding unrelated user settings.
        var config = MacToolsConfiguration(); config.mouse.reverseVertical = true; config.hyperEnabled = true
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        var oldMouse = object["mouse"] as! [String: Any]; oldMouse.removeValue(forKey: "modifiers"); object["mouse"] = oldMouse
        let decoded = try JSONDecoder().decode(MacToolsConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        try check(decoded == config, "existing configuration loads with default modifier rules")
        for modifier in WheelModifier.allCases {
            for action in WheelModifierAction.allCases {
                config.mouse.modifiers[modifier] = WheelModifierRule(action: action, speed: 2.5)
                try config.validate()
                let saved = try JSONEncoder().encode(config)
                try check(try JSONDecoder().decode(MacToolsConfiguration.self, from: saved) == config, "all modifier actions and speeds round-trip")
            }
        }
        for invalid in [0.0, 5.1, Double.nan, Double.infinity] {
            config.mouse.modifiers.option.speed = invalid
            var rejected = false; do { try config.validate() } catch { rejected = true }
            try check(rejected, "invalid modifier multiplier rejected")
        }
        oldMouse["modifiers"] = ["shift": ["action": "unknown", "speed": 1]]; object["mouse"] = oldMouse
        var rejected = false
        do { _ = try JSONDecoder().decode(MacToolsConfiguration.self, from: JSONSerialization.data(withJSONObject: object)) } catch { rejected = true }
        try check(rejected, "corrupt modifier configuration is not silently defaulted")

        for smooth in [false, true] {
            for (index, modifier) in WheelModifier.allCases.enumerated() {
                for action in WheelModifierAction.allCases {
                    var p = MousePreferences(); p.smooth = smooth
                    p.modifiers[modifier] = WheelModifierRule(action: action, speed: 2)
                    var time = 1.0; var output: [CGEvent] = []
                    let physical: CGEventFlags = [.maskAlphaShift, .maskAlternate]
                    let processor = MouseScrollProcessor(preferences: p, now: { time }, sink: { output.append($0.copy()!); return true }, schedule: { _ in {} }, physicalFlags: { physical })
                    let inputFlags = CGEventFlags(rawValue: flags[index].rawValue | masks[index] | CGEventFlags.maskAlphaShift.rawValue)
                    let event = wheel(inputFlags)
                    let result = processor.transform(event)
                    switch action {
                    case .application:
                        try check(result === event && event.flags == inputFlags && event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3 && output.isEmpty, "application action passes raw event")
                    case .block:
                        for _ in 0..<100 { time += 1.0/120; processor.tick() }
                        try check(result == nil && output.isEmpty, "block emits no event or delayed tail")
                    case .zoom:
                        try check(result == nil && output.count == 3, "zoom consumes one input with one complete key sequence")
                        try check(output[0].type == .keyDown && output[1].type == .keyUp && output[2].type == .flagsChanged, "zoom sequence is down/up/restore")
                        try check(output[0].getIntegerValueField(.keyboardEventKeycode) == 69 && output[1].getIntegerValueField(.keyboardEventKeycode) == 69 && output[0].flags == .maskCommand && output[1].flags == .maskCommand && output[2].flags == physical, "zoom strips trigger and restores physical modifiers")
                        try check(output.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == MouseScrollProcessor.marker }, "zoom bypasses own mouse and Hyper processing")
                        let count = output.count
                        for e in output { try check(processor.transform(e) === e, "marked synthetic keys do not reenter") }
                        for _ in 0..<100 { time += 1.0/120; processor.tick() }
                        try check(output.count == count, "zoom has no smooth repeat")
                    case .changeAxis, .changeSpeed:
                        if let result { output.append(result) }
                        for _ in 0..<600 { time += 1.0/120; processor.tick() }
                        try check(!output.isEmpty && output.allSatisfy { $0.flags == .maskAlphaShift }, "handled flags including both device bits are cleared")
                        if action == .changeAxis {
                            try check(output.contains { $0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) > 0 } && output.allSatisfy { $0.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) == 0 }, "axis action works with and without smoothing for each modifier")
                        } else {
                            try check(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) == wheel().getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * 2, "configured multiplier scales source point deltas")
                        }
                    }
                }
            }
        }
        // Multiple modifiers, Fn and native continuous input always stay native.
        var p = MousePreferences(); p.reverseVertical = true; p.scrollSpeed = 5
        for modifier in WheelModifier.allCases { p.modifiers[modifier].action = .block }
        let native = MouseScrollProcessor(preferences: p, sink: { _ in fatalError("native event cannot emit") }, schedule: { _ in nil })
        for combination: CGEventFlags in [[.maskShift, .maskCommand], [.maskShift, .maskAlternate], [.maskShift, .maskControl], [.maskCommand, .maskAlternate], [.maskCommand, .maskControl], [.maskAlternate, .maskControl], [.maskControl, .maskAlternate, .maskShift], [.maskCommand, .maskControl, .maskAlternate, .maskShift], [.maskShift, .maskSecondaryFn]] {
            let e = wheel(combination)
            try check(native.transform(e) === e && e.flags == combination && e.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3, "multi-modifier/Meh/Hyper/Fn remains native even when rules block")
        }
        let pixel = wheel(.maskShift, pixel: true)
        try check(native.transform(pixel) === pixel, "continuous input does not trigger modifier action")
        p.scrolling = false
        let disabled = MouseScrollProcessor(preferences: p, sink: { _ in false }, schedule: { _ in nil })
        let raw = wheel(.maskShift); try check(disabled.transform(raw) === raw, "scrolling switch disables modifier actions")

        // A new application-owned or blocked gesture flushes only outstanding input.
        for action: WheelModifierAction in [.application, .block, .zoom] {
            var p = MousePreferences(); p.modifiers.option.action = action
            var time = 1.0; var output: [CGEvent] = []
            let processor = MouseScrollProcessor(preferences: p, now: { time }, sink: { output.append($0.copy()!); return true }, schedule: { _ in {} }, physicalFlags: { [] })
            _ = processor.transform(wheel())
            _ = processor.transform(wheel(.maskAlternate))
            let expected = action == .zoom ? 4 : 1
            for _ in 0..<600 { time += 1.0/120; processor.tick() }
            try check(output.count == expected && output[0].type == .scrollWheel && output[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3, "action boundary preserves pending tick and cancels tail")
        }
        // Key allocation must finish before the original wheel can be consumed.
        p = MousePreferences(); p.modifiers.option.action = .zoom
        for failAt in 1...3 {
            var allocations = 0; var output: [CGEvent] = []
            let processor = MouseScrollProcessor(preferences: p, sink: { output.append($0); return true }, schedule: { _ in nil }, keyFactory: { code, down in
                allocations += 1
                return allocations == failAt ? nil : CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            })
            let e = wheel(.maskAlternate)
            try check(processor.transform(e) === e && output.isEmpty && e.flags == .maskAlternate, "zoom allocation failure leaves original wheel untouched")
        }
        for reversed in [false, true] {
            p.reverseVertical = reversed
            var output: [CGEvent] = []
            let processor = MouseScrollProcessor(preferences: p, sink: { output.append($0); return true }, schedule: { _ in nil }, physicalFlags: { [] })
            _ = processor.transform(wheel(.maskAlternate, y: -3))
            try check(output[0].getIntegerValueField(.keyboardEventKeycode) == (reversed ? 69 : 78), "zoom direction follows reverse setting")
        }
        print("WheelModifierTests: \(checks) checks passed (constructed events only, no global input)")
    }
}
