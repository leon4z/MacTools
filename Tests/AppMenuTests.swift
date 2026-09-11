import AppKit
import Foundation

@main
enum AppMenuTests {
    static func main() throws {
        let application = NSApplication.shared
        AppMenu.install(in: application)

        guard
            let editMenu = application.mainMenu?.items.first(where: { $0.title == "编辑" })?.submenu,
            let pasteItem = editMenu.items.first(where: { $0.action == #selector(NSText.paste(_:)) })
        else {
            throw TestFailure("missing Edit > Paste menu item")
        }

        try expect(pasteItem.keyEquivalent == "v", "Paste uses the V key")
        try expect(pasteItem.keyEquivalentModifierMask == [.command], "Paste uses the Command modifier")
        try expect(pasteItem.action == #selector(NSText.paste(_:)), "Paste uses the standard responder action")
        try expect(pasteItem.target == nil, "Paste is routed to the current first responder")
        print("AppMenuTests: all tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
