import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: TapShortcut
    @Binding var recording: Bool
    func makeNSView(context: Context) -> RecorderField { RecorderField() }
    static func dismantleNSView(_ view: RecorderField, coordinator: ()) {
        view.onRecord = nil
        _ = view.resignFirstResponder()
        view.onFocus = nil
    }
    func updateNSView(_ view: RecorderField, context: Context) {
        view.label = shortcut.label
        view.onFocus = { recording = $0 }
        view.onRecord = { shortcut = $0; recording = false }
        if !recording && view.isRecording { view.window?.makeFirstResponder(nil) }
        view.needsDisplay = true
    }
}

final class RecorderField: NSView {
    var label = "不执行操作"
    var isRecording = false
    var onFocus: ((Bool) -> Void)?
    var onRecord: ((TapShortcut) -> Void)?
    private var pending: TapShortcut?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool { pending = nil; isRecording = true; onFocus?(true); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { pending = nil; isRecording = false; onFocus?(false); needsDisplay = true; return true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }; keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording, pending == nil, !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.command) { prefix += "⌘" }
        if flags.contains(.shift) { prefix += "⇧" }
        let names: [UInt16: String] = [53:"Esc", 36:"Return", 48:"Tab", 49:"Space", 51:"Delete", 123:"←", 124:"→", 125:"↓", 126:"↑"]
        let name = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        // Keep the module suspended until this key is released. Re-registering
        // Carbon during keyDown could execute the newly saved action on repeat.
        pending = TapShortcut(keyCode: event.keyCode, label: prefix + name, modifiers: UInt64(flags.rawValue))
        needsDisplay = true
    }
    override func keyUp(with event: NSEvent) {
        guard isRecording, let candidate = pending, candidate.keyCode == event.keyCode else { return }
        pending = nil
        onRecord?(candidate)
        window?.makeFirstResponder(nil)
    }
    override func draw(_ dirtyRect: NSRect) {
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let text = isRecording ? (pending.map { $0.label + "  · 松开以保存" } ?? "请按下按键或组合键…") : (label + "  · 点击录制")
        (text as NSString).draw(at: NSPoint(x: 10, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
    }
}
