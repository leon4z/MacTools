import Foundation

struct ShortcutPreset: Identifiable {
    let id: Int
    let title: String
    let keyCode: UInt16?
    var shortcut: TapShortcut { TapShortcut(keyCode: keyCode, label: title, modifiers: 0) }

    static let all: [ShortcutPreset] = [
        .init(id: 0, title: "不执行操作", keyCode: nil),
        .init(id: 55, title: "左 ⌘ Command", keyCode: 55), .init(id: 54, title: "右 ⌘ Command", keyCode: 54),
        .init(id: 58, title: "左 ⌥ Option", keyCode: 58), .init(id: 61, title: "右 ⌥ Option", keyCode: 61),
        .init(id: 59, title: "左 ⌃ Control", keyCode: 59), .init(id: 62, title: "右 ⌃ Control", keyCode: 62),
        .init(id: 56, title: "左 ⇧ Shift", keyCode: 56), .init(id: 60, title: "右 ⇧ Shift", keyCode: 60),
        .init(id: 53, title: "Esc", keyCode: 53), .init(id: 48, title: "Tab", keyCode: 48),
        .init(id: 36, title: "回车", keyCode: 36), .init(id: 51, title: "退格", keyCode: 51),
        .init(id: 49, title: "空格", keyCode: 49), .init(id: 123, title: "←", keyCode: 123),
        .init(id: 124, title: "→", keyCode: 124), .init(id: 125, title: "↓", keyCode: 125),
        .init(id: 126, title: "↑", keyCode: 126)
    ]
    static func selection(for shortcut: TapShortcut) -> Int {
        all.first { $0.keyCode == shortcut.keyCode && shortcut.modifiers == 0 }?.id ?? -1
    }
}
