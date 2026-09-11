import Foundation
import CoreGraphics

@main enum InputPolicyTests {
    static var count = 0
    static func check(_ value: Bool, _ description: String) throws {
        count += 1
        if !value { throw NSError(domain: "InputPolicyTests", code: count, userInfo: [NSLocalizedDescriptionKey: description]) }
    }
    static func main() throws {
        var scroll = ScrollSmoother()
        scroll.add(x: 75, y: -240)
        var totalX = 0.0, totalY = 0.0
        for _ in 0..<300 { let d = scroll.step(dt: 1.0/120, duration: 0.16); totalX += d.0; totalY += d.1 }
        try check(abs(totalX-75) < 0.00001 && abs(totalY+240) < 0.00001, "smooth scroll preserves total on both axes")
        try check(scroll.isEmpty, "smooth scroll terminates")
        scroll.add(x: 20, y: 100); scroll.add(x: -5, y: 10)
        try check(scroll.x == -5 && scroll.y == 110, "direction reversal cancels only reversed axis")
        scroll.reset(); try check(scroll.isEmpty, "disable discards pending tail")
        scroll.add(x: 99999, y: -99999)
        try check(scroll.x == 99999 && scroll.y == -99999, "large scroll bursts are not silently truncated")
        let tap = TapShortcut(keyCode: 53, label: "Esc", modifiers: 0)
        let mapping = ModifierMapping(enabled: true, trigger: .capsLock, tap: tap)
        var state = HyperState()
        state.down(mapping: mapping, flags: [.maskControl, .maskAlternate, .maskCommand])
        try check(state.modifiers == [.maskControl, .maskAlternate, .maskCommand], "hyper holds all modifiers")
        try check(state.up(code: mapping.trigger.keyCode) == tap, "standalone tap maps to Escape")
        try check(state.modifiers.isEmpty, "release clears state")
        try check(state.up(code: mapping.trigger.keyCode) == nil, "release cannot replay tap")
        state.down(mapping: mapping, flags: [.maskControl]); state.markUsed()
        try check(state.up(code: mapping.trigger.keyCode) == nil, "chord does not fire tap on release")
        state.down(mapping: mapping, flags: [.maskControl]); state.down(mapping: mapping, flags: [.maskControl])
        try check(state.pressed.count == 1, "repeat does not produce another press")
        state.reset()
        try check(state.modifiers.isEmpty && state.up(code: mapping.trigger.keyCode) == nil, "stop/sleep reset never emits a tap")
        let capsTap = TapShortcut(keyCode: 57, label: "Caps Lock")
        let dualRoleCaps = ModifierMapping(enabled: true, trigger: .capsLock, tap: capsTap)
        for chord: CGEventFlags in [[.maskControl, .maskAlternate, .maskShift], [.maskControl, .maskAlternate, .maskShift, .maskCommand]] {
            state.down(mapping: dualRoleCaps, flags: chord)
            state.down(mapping: dualRoleCaps, flags: chord)
            try check(state.up(code: 79) == capsTap, "Caps alone emits one native lock toggle despite repeats")
            try check(state.up(code: 79) == nil, "Caps release cannot toggle twice")
            state.down(mapping: dualRoleCaps, flags: chord)
            state.markUsed()
            let flags = state.outputFlags(raw: [.maskAlphaShift], mappings: [dualRoleCaps], apply: true)
            try check(flags == chord.union(.maskAlphaShift), "Meh/Hyper chord preserves existing Caps Lock")
            try check(state.up(code: 79) == nil, "Caps chord never toggles lock on release")
            state.down(mapping: dualRoleCaps, flags: chord); state.reset()
            try check(state.up(code: 79) == nil, "stopping input while Caps held never toggles lock")
        }
        let second = ModifierMapping(enabled: true, trigger: .rightOption, tap: tap)
        state.down(mapping: mapping, flags: [.maskControl]); state.down(mapping: second, flags: [.maskShift])
        try check(state.modifiers == [.maskControl, .maskShift], "two triggers combine")
        try check(state.up(code: second.trigger.keyCode) == nil && state.up(code: mapping.trigger.keyCode) == nil, "two triggers count as a chord for both")
        let left = ModifierMapping(enabled: true, trigger: .leftOption)
        state.down(mapping: left, flags: [.maskControl, .maskShift])
        let raw = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20 | 0x40)
        let flags = state.outputFlags(raw: raw, mappings: [left], apply: true)
        try check(flags.contains(.maskAlternate) && flags.contains(.maskControl), "physical opposite-side modifier survives")
        let mouseFlags = state.outputFlags(raw: [.maskAlternate], mappings: [left], apply: false)
        try check(!mouseFlags.contains(.maskControl), "excluded mouse events do not gain hyper modifiers")
        var config = MacToolsConfiguration()
        try check(config.finderActive && !config.mouseActive && !config.hyperActive, "new modules default off, Finder preserved")
        config.mouseEnabled = true; config.hyperEnabled = true; config.allEnabled = false
        try check(!config.finderActive && !config.mouseActive && !config.hyperActive, "global pause gates all modules")
        config.allEnabled = true
        try check(config.finderActive && config.mouseActive && config.hyperActive, "resume retains module preferences")
        config.hyper.hyper.enabled = true; config.hyper.meh.enabled = true; config.hyper.meh.trigger = .capsLock
        var rejected = false
        do { try config.validate() } catch { rejected = true }
        try check(rejected, "same source cannot be Hyper and Meh")
        config = MacToolsConfiguration(); config.mouse.scrollSpeed = .nan
        rejected = false
        do { try config.validate() } catch { rejected = true }
        try check(rejected, "nonfinite parameters rejected")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        config = MacToolsConfiguration(); config.hyper.meh.tap = tap
        try MacToolsConfigurationStore.save(config, to: url)
        try check(try MacToolsConfigurationStore.load(from: url) == config, "configuration round trip includes tap mapping")
        try Data("invalid".utf8).write(to: url)
        rejected = false
        do { _ = try MacToolsConfigurationStore.load(from: url) } catch { rejected = true }
        try check(rejected, "corrupt configuration is not silently overwritten")
        print("InputPolicyTests: \(count) checks passed")
    }
}
