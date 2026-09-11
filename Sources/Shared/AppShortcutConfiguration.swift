import Foundation

struct AppShortcut: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var bundleIdentifier: String
    var applicationPath: String
    var shortcut = TapShortcut()
    var enabled = true
}

struct AppShortcutConfiguration: Codable, Equatable {
    var version = 1
    var enabled = false
    var apps: [AppShortcut] = []
    func validate() throws {
        guard version == 1, apps.count <= 100, Set(apps.map(\.id)).count == apps.count else { throw AppShortcutError.message("应用快捷键配置无效。") }
        var chords = Set<String>()
        for app in apps {
            guard !app.name.isEmpty, !app.bundleIdentifier.isEmpty, app.applicationPath.hasPrefix("/"), app.applicationPath.lowercased().hasSuffix(".app") else { throw AppShortcutError.message("请选择有效的应用。") }
            guard let code = app.shortcut.keyCode else { continue }
            let allowed: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
            let required: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
            guard code <= 127, ![54,55,56,57,58,59,60,61,62,63,79].contains(code),
                  app.shortcut.modifiers & required != 0, app.shortcut.modifiers & ~allowed == 0 else {
                throw AppShortcutError.message("应用快捷键需要 ⌘、⌥ 或 ⌃ 搭配普通按键；F18 保留给 Caps Lock 映射。")
            }
            if app.enabled && !chords.insert("\(code):\(app.shortcut.modifiers)").inserted {
                throw AppShortcutError.message("这个快捷键已分配给其他应用，请换一个组合。")
            }
        }
    }
}

enum AppShortcutError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum AppShortcutStore {
    // Separate versioned file: adding this module does not rewrite mouse/Meh settings.
    static var url: URL { ToolConfigurationStore.sharedApplicationSupportURL().appendingPathComponent("AppShortcuts.json") }
    static func load(from url: URL = url) throws -> AppShortcutConfiguration {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return AppShortcutConfiguration() }
        let configuration = try JSONDecoder().decode(AppShortcutConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }
    static func save(_ configuration: AppShortcutConfiguration, to url: URL = url) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
}
