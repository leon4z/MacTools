import AppKit
import FinderSync
import Foundation

final class FinderSync: FIFinderSync {
    private let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacTools-Finder.log")
    private let toolMenuCache = ToolMenuCache()
    private var openToolIDsByTag: [Int: String] = [:]
    private var nextOpenToolTag = 1_000

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard MacToolsConfigurationStore.finderActive else { return nil }
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }

        let selectedURLs = currentSelection(for: menuKind)
        guard !selectedURLs.isEmpty else {
            return nil
        }

        let menu = NSMenu(title: "MacTools")
        let copyItem = NSMenuItem(
            title: selectedURLs.count > 1 ? "拷贝路径 (\(selectedURLs.count) 项)" : "拷贝路径",
            action: #selector(copyFullPaths(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)

        if menuKind == .contextualMenuForItems {
            let moveItem = NSMenuItem(
                title: "移动到…",
                action: #selector(moveItems(_:)),
                keyEquivalent: ""
            )
            moveItem.target = self
            menu.addItem(moveItem)
        }

        if selectedURLs.count == 1, directoryForNewFile(from: selectedURLs[0]) != nil {
            let newFileItem = NSMenuItem(
                title: "新建文件",
                action: #selector(newFile(_:)),
                keyEquivalent: ""
            )
            newFileItem.target = self
            newFileItem.tag = Int(menuKind.rawValue)
            menu.addItem(newFileItem)
        }

        if selectedURLs.count == 1 {
            let tools = toolMenuCache.entries()
            if !tools.isEmpty {
                openToolIDsByTag.removeAll(keepingCapacity: true)
                nextOpenToolTag = 1_000
                let openSubmenuItem = NSMenuItem(title: "用工具打开", action: nil, keyEquivalent: "")
                let openSubmenu = NSMenu(title: "用工具打开")

                for tool in tools {
                    let item = NSMenuItem(
                        title: tool.name,
                        action: #selector(openWithTool(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = tagForOpenTool(tool.id)
                    item.image = tool.icon
                    openSubmenu.addItem(item)
                }

                openSubmenuItem.submenu = openSubmenu
                menu.addItem(openSubmenuItem)
            }
        }

        return menu
    }

    private func currentSelection(for menuKind: FIMenuKind? = nil) -> [URL] {
        let controller = FIFinderSyncController.default()

        if menuKind == .contextualMenuForContainer, let targeted = controller.targetedURL() {
            return [targeted]
        }

        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }

        if let targeted = controller.targetedURL() {
            return [targeted]
        }

        return []
    }

    private func tagForOpenTool(_ toolID: String) -> Int {
        let tag = nextOpenToolTag
        nextOpenToolTag += 1
        openToolIDsByTag[tag] = toolID
        return tag
    }

    private func directoryForNewFile(from url: URL) -> URL? {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? url : url.deletingLastPathComponent()
    }

    private func currentNewFileDirectory(menuKind: FIMenuKind?) -> URL? {
        let controller = FIFinderSyncController.default()

        if menuKind == .contextualMenuForContainer, let targeted = controller.targetedURL() {
            return directoryForNewFile(from: targeted)
        }

        let selected = controller.selectedItemURLs() ?? []
        guard selected.count <= 1 else {
            return nil
        }

        if let targeted = controller.targetedURL() {
            return directoryForNewFile(from: targeted)
        }

        if let first = selected.first {
            return directoryForNewFile(from: first)
        }

        return nil
    }

    @objc private func copyFullPaths(_ sender: NSMenuItem) {
        guard MacToolsConfigurationStore.finderActive else { return }
        let paths = currentSelection().map(\.path)
        guard !paths.isEmpty else {
            log("copyFullPaths: no current selection")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        log("copyFullPaths: copied=\(copied) count=\(paths.count) value=\(paths.joined(separator: " | "))")
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        guard MacToolsConfigurationStore.finderActive else { return }
        let menuKind = FIMenuKind(rawValue: UInt(sender.tag))
        guard let directoryURL = currentNewFileDirectory(menuKind: menuKind) else {
            log("newFile: no target directory")
            return
        }

        var components = URLComponents()
        components.scheme = "mactools"
        components.host = "new-file"
        components.queryItems = [
            URLQueryItem(name: "directoryPath", value: directoryURL.path)
        ]

        guard let callbackURL = components.url else {
            log("newFile: failed to build callback URL")
            return
        }

        let opened = NSWorkspace.shared.open(callbackURL)
        log("newFile: delegated=\(opened) directory=\(directoryURL.path)")
    }

    @objc private func moveItems(_ sender: NSMenuItem) {
        guard MacToolsConfigurationStore.finderActive else { return }
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !selectedURLs.isEmpty else {
            log("moveItems: no current selection")
            return
        }

        let requestID = UUID().uuidString
        let payload = MoveRequestPayload(
            requestID: requestID,
            createdAt: Date(),
            sourcePaths: selectedURLs.map(\.path)
        )

        do {
            try MoveRequestStore.writeFromExtension(payload)
        } catch {
            log("moveItems: failed to persist request count=\(selectedURLs.count)")
            return
        }

        var components = URLComponents()
        components.scheme = "mactools"
        components.host = "move"
        components.queryItems = [
            URLQueryItem(name: "requestID", value: requestID)
        ]

        guard let callbackURL = components.url else {
            log("moveItems: failed to build callback URL count=\(selectedURLs.count)")
            return
        }

        let opened = NSWorkspace.shared.open(callbackURL)
        log("moveItems: delegated=\(opened) count=\(selectedURLs.count)")
    }

    @objc private func openWithTool(_ sender: NSMenuItem) {
        guard MacToolsConfigurationStore.finderActive else { return }
        let selectedURLs = currentSelection()
        guard
            selectedURLs.count == 1,
            let toolID = openToolIDsByTag[sender.tag]
        else {
            log("openWithTool: invalid selection or payload")
            return
        }

        let selectedURL = selectedURLs[0]
        let requestID = UUID().uuidString
        let payload = OpenToolRequestPayload(
            requestID: requestID,
            createdAt: Date(),
            toolID: toolID,
            selectedPath: selectedURL.path
        )

        do {
            try OpenToolRequestStore.writeFromExtension(payload)
        } catch {
            log("openWithTool: failed to persist request toolID=\(toolID)")
            return
        }

        let request = OpenToolRequest(requestID: requestID)
        guard let callbackURL = request.callbackURL else {
            OpenToolRequestStore.discardFromExtension(requestID: requestID)
            log("openWithTool: failed to build callback URL")
            return
        }

        let opened = NSWorkspace.shared.open(callbackURL)
        if !opened {
            OpenToolRequestStore.discardFromExtension(requestID: requestID)
        }
        log("openWithTool: delegated=\(opened) toolID=\(toolID) selected=\(selectedURL.path)")
    }

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
