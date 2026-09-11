import AppKit

/// Obtain scoped access to the Finder extension’s shared configuration directory.
/// This is file-access authorization, independent of input Accessibility permission.
@MainActor
enum SharedConfigurationAccess {
    private static let bookmarkKey = "MacTools.SharedConfigurationBookmark"
    private static var scopedURL: URL?
    static var directory: URL { ToolConfigurationStore.sharedApplicationSupportURL() }

    static func restore() {
        guard scopedURL == nil, let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.standardizedFileURL == directory.standardizedFileURL else { return }
            _ = url.startAccessingSecurityScopedResource()
            scopedURL = url
            if stale { try saveBookmark(url) }
        } catch {
            // Never delete settings or replace unreadable configuration with defaults.
        }
    }
    static func reconnect() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "访问 MacTools 配置"
        panel.message = "请选择已定位的 MacTools 配置文件夹，允许读取和保存设置。"
        panel.prompt = "允许访问"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        guard selected.standardizedFileURL == directory.standardizedFileURL else {
            throw NSError(domain: "MacTools.ConfigurationAccess", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请选择 MacTools 配置文件夹。"])
        }
        _ = selected.startAccessingSecurityScopedResource()
        do {
            // Verify actual reads before persisting the grant.
            _ = try MacToolsConfigurationStore.load()
            _ = try AppShortcutStore.load()
            try saveBookmark(selected)
        } catch {
            selected.stopAccessingSecurityScopedResource()
            throw error
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = selected
        return true
    }
    private static func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }
}
