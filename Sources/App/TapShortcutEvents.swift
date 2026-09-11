import CoreGraphics

enum TapShortcutEvents {
    /// Allocate the complete pair before posting, so allocation failure cannot
    /// leave a synthetic modifier pressed. Keep other held modifiers intact.
    static func make(_ shortcut: TapShortcut, baseFlags: CGEventFlags, marker: Int64) -> [CGEvent] {
        guard let code = shortcut.keyCode,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return [] }
        if let modifier = ModifierTrigger.allCases.first(where: { $0 != .capsLock && $0.keyCode == code }) {
            down.type = .flagsChanged; up.type = .flagsChanged
            down.flags = baseFlags.union(modifier.nativeFlag).union(CGEventFlags(rawValue: modifier.deviceMask))
            up.flags = baseFlags
        } else {
            down.flags = baseFlags.union(CGEventFlags(rawValue: shortcut.modifiers))
            up.flags = baseFlags.union(CGEventFlags(rawValue: shortcut.modifiers))
        }
        for event in [down, up] { event.setIntegerValueField(.eventSourceUserData, value: marker) }
        return [down, up]
    }
}
