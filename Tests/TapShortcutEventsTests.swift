import CoreGraphics
import Foundation

@main enum TapShortcutEventsTests {
    static func main() {
        let baseline: CGEventFlags = [.maskAlphaShift, .maskSecondaryFn]
        for modifier in ModifierTrigger.allCases where modifier != .capsLock {
            let shortcut = ShortcutPreset.all.first { $0.keyCode == modifier.keyCode }!.shortcut
            let events = TapShortcutEvents.make(shortcut, baseFlags: baseline, marker: 42)
            precondition(events.count == 2)
            precondition(events.allSatisfy { $0.type == .flagsChanged && $0.getIntegerValueField(.keyboardEventKeycode) == Int64(modifier.keyCode) })
            precondition(events[0].flags.contains(modifier.nativeFlag))
            precondition(events[0].flags.rawValue & modifier.deviceMask != 0)
            precondition(events[1].flags == baseline, "release preserves other held modifiers")
            precondition(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 42 })
            let held = baseline.union(modifier.nativeFlag).union(CGEventFlags(rawValue: modifier.deviceMask))
            precondition(TapShortcutEvents.make(shortcut, baseFlags: held, marker: 42)[1].flags == held)
        }
        for preset in ShortcutPreset.all where preset.keyCode != nil && ![54,55,56,58,59,60,61,62].contains(preset.keyCode!) {
            let events = TapShortcutEvents.make(preset.shortcut, baseFlags: baseline, marker: 42)
            precondition(events.map(\.type) == [.keyDown, .keyUp])
            precondition(events.allSatisfy { $0.flags == baseline })
            precondition(ShortcutPreset.selection(for: preset.shortcut) == preset.id)
        }
        precondition(TapShortcutEvents.make(TapShortcut(), baseFlags: [], marker: 42).isEmpty)
        let combo = TapShortcut(keyCode: 0, label: "⌘A", modifiers: CGEventFlags.maskCommand.rawValue)
        precondition(ShortcutPreset.selection(for: combo) == -1)
        precondition(TapShortcutEvents.make(combo, baseFlags: baseline, marker: 42).allSatisfy { $0.flags == baseline.union(.maskCommand) })
        print("TapShortcutEventsTests: all tests passed (events inspected only; no global input posted)")
    }
}
