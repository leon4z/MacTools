import Foundation
import CoreGraphics

/// An exponential scroll tail. Emitted delta plus remaining delta is
/// exactly the input total; reversing an axis discards that axis's old tail.
struct ScrollSmoother {
    private(set) var x = 0.0
    private(set) var y = 0.0
    mutating func add(x dx: Double, y dy: Double) {
        if dx * x < 0 { x = 0 }
        if dy * y < 0 { y = 0 }
        guard dx.isFinite && dy.isFinite else { return }
        x += dx
        y += dy
    }
    mutating func step(dt: Double, duration: Double) -> (Double, Double) {
        let fraction = 1 - exp(-min(max(dt, 0), 0.05) / max(0.01, duration / 4))
        func take(_ value: inout Double) -> Double {
            let result = abs(value) < 0.1 ? value : value * fraction
            value -= result
            return result
        }
        return (take(&x), take(&y))
    }
    var isEmpty: Bool { x == 0 && y == 0 }
    mutating func reset() { x = 0; y = 0 }
}

extension ModifierTrigger {
    var nativeFlag: CGEventFlags {
        switch self {
        case .capsLock: return []
        case .leftControl, .rightControl: return .maskControl
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftShift, .rightShift: return .maskShift
        }
    }
    var deviceMask: UInt64 {
        switch self {
        case .capsLock: return 0
        case .leftControl: return 0x1
        case .rightControl: return 0x2000
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .leftCommand: return 0x8
        case .rightCommand: return 0x10
        case .leftShift: return 0x2
        case .rightShift: return 0x4
        }
    }
    var counterpartMask: UInt64 {
        switch self {
        case .capsLock: return 0
        case .leftControl: return 0x2000
        case .rightControl: return 0x1
        case .leftOption: return 0x40
        case .rightOption: return 0x20
        case .leftCommand: return 0x10
        case .rightCommand: return 0x8
        case .leftShift: return 0x4
        case .rightShift: return 0x2
        }
    }
}

struct HyperState {
    struct Press {
        let mapping: ModifierMapping
        let flags: CGEventFlags
        var used = false
    }
    private(set) var pressed: [UInt16: Press] = [:]
    var modifiers: CGEventFlags { pressed.values.reduce(CGEventFlags()) { $0.union($1.flags) } }
    mutating func down(mapping: ModifierMapping, flags: CGEventFlags) {
        guard pressed[mapping.trigger.keyCode] == nil else { return }
        if !pressed.isEmpty { markUsed() }
        pressed[mapping.trigger.keyCode] = Press(mapping: mapping, flags: flags, used: !pressed.isEmpty)
    }
    mutating func up(code: UInt16) -> TapShortcut? {
        guard let press = pressed.removeValue(forKey: code), !press.used else { return nil }
        return press.mapping.tap.keyCode == nil ? nil : press.mapping.tap
    }
    mutating func markUsed() {
        for key in Array(pressed.keys) { pressed[key]?.used = true }
    }
    mutating func reset() { pressed.removeAll() }
    func outputFlags(raw: CGEventFlags, mappings: [ModifierMapping], apply: Bool) -> CGEventFlags {
        var result = raw
        for m in mappings where m.enabled {
            let source = m.trigger
            if raw.rawValue & source.counterpartMask == 0 { result.subtract(source.nativeFlag) }
            result = CGEventFlags(rawValue: result.rawValue & ~source.deviceMask)
        }
        if apply { result.formUnion(modifiers) }
        return result
    }
}
