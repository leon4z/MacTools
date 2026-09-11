import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor final class AppShortcutModel: ObservableObject {
    @Published private(set) var configuration = AppShortcutConfiguration()
    @Published private(set) var status = "未开启应用快捷键。"
    @Published private(set) var issues: [UUID: String] = [:]
    @Published var errorMessage: String?
    @Published private(set) var configurationLoaded = false
    @Published var recording = false { didSet { apply() } }
    var onHotKeyActivation: (() -> Void)?
    private let registry: AppHotKeyRegistering
    private let storageURL: URL
    private let resolve: (AppShortcut) -> URL?
    private let launch: (URL, @escaping (String?) -> Void) -> Void
    private let frontmostBundleIdentifier: () -> String?
    private let hideFrontmost: (String) -> Bool
    private var allEnabled = false
    private var inputRecording = false
    private var suspended = false
    private var generation = 0
    private var launching = Set<UUID>()
    private var mappedActions: [String: () -> Void] = [:]
    private var consumedKeys = Set<UInt16>()
    private var registrationIssues: [UUID: String] = [:]

    init(registry: AppHotKeyRegistering? = nil, storageURL: URL = AppShortcutStore.url,
         resolve: @escaping (AppShortcut) -> URL? = AppShortcutModel.resolveApplication,
         frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         hideFrontmost: @escaping (String) -> Bool = { identifier in
             guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == identifier else { return false }
             return app.hide()
         },
         launch: @escaping (URL, @escaping (String?) -> Void) -> Void = { url, completion in
             let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
             NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                 DispatchQueue.main.async { completion(error?.localizedDescription) }
             }
         }) {
        self.registry = registry ?? AppHotKeyRegistry(); self.storageURL = storageURL; self.resolve = resolve; self.launch = launch
        self.frontmostBundleIdentifier = frontmostBundleIdentifier; self.hideFrontmost = hideFrontmost
        reloadConfiguration()
    }
    func reloadConfiguration() {
        do {
            configuration = try AppShortcutStore.load(from: storageURL)
            configurationLoaded = true
            errorMessage = nil
        } catch {
            configurationLoaded = false
            stop()
            errorMessage = "无法读取应用快捷键配置：" + error.localizedDescription
        }
    }
    nonisolated static func resolveApplication(_ app: AppShortcut) -> URL? {
        let preferred = URL(fileURLWithPath: app.applicationPath)
        if Bundle(url: preferred)?.bundleIdentifier == app.bundleIdentifier { return preferred }
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier),
              Bundle(url: found)?.bundleIdentifier == app.bundleIdentifier else { return nil }
        return found
    }
    func setContext(allEnabled: Bool, inputRecording: Bool) {
        self.allEnabled = allEnabled; self.inputRecording = inputRecording; suspended = false; apply()
    }
    func stop() { suspended = true; generation += 1; registry.unregisterAll(); mappedActions.removeAll(); consumedKeys.removeAll(); launching.removeAll() }
    /// Session-tap modifiers may be applied after WindowServer's Carbon matching.
    /// Consume only internally mapped chords whose Carbon registration succeeded.
    /// Application resolution/launch is deferred outside the input callback.
    func handleMappedKey(_ type: CGEventType, _ event: CGEvent, mappingActive: Bool) -> Bool {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp { return consumedKeys.remove(code) != nil }
        guard type == .keyDown else { return false }
        if consumedKeys.contains(code) { return true }
        guard mappingActive, let action = mappedActions[Self.chord(code, event.flags.rawValue)] else { return false }
        consumedKeys.insert(code)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { action() }
        }
        return true
    }
    private static func chord(_ code: UInt16, _ flags: UInt64) -> String {
        "\(code):\(AppHotKeyRegistry.carbonModifiers(flags))"
    }
    func update(_ change: (inout AppShortcutConfiguration) -> Void) {
        guard configurationLoaded else {
            errorMessage = "原快捷键配置尚未读取，已阻止保存。请先重新连接配置。"
            return
        }
        var next = configuration; change(&next)
        do {
            try AppShortcutStore.save(next, to: storageURL)
            configuration = next; apply()
        } catch { errorMessage = error.localizedDescription }
    }
    func updateApp(_ id: UUID, _ change: (inout AppShortcut) -> Void) {
        update { value in if let index = value.apps.firstIndex(where: { $0.id == id }) { change(&value.apps[index]) } }
    }
    func addApplication() {
        recording = false
        let panel = NSOpenPanel(); panel.title = "选择要设置快捷键的应用"
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var additions: [AppShortcut] = []
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            guard !configuration.apps.contains(where: { $0.bundleIdentifier == id }), !additions.contains(where: { $0.bundleIdentifier == id }) else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            additions.append(AppShortcut(name: name, bundleIdentifier: id, applicationPath: url.path))
        }
        update { $0.apps.append(contentsOf: additions) }
    }
    func toggle(_ app: AppShortcut) {
        guard !launching.contains(app.id) else { return }
        if frontmostBundleIdentifier() == app.bundleIdentifier {
            // Same behavior as Thor: hide the foreground target and let macOS
            // restore the previously active application using its own ordering.
            if hideFrontmost(app.bundleIdentifier) { issues[app.id] = registrationIssues[app.id] }
            else { issues[app.id] = "无法隐藏应用，请重试。" }
        } else {
            activate(app)
        }
    }
    func activate(_ app: AppShortcut) {
        guard !launching.contains(app.id) else { return }
        guard let url = resolve(app) else { issues[app.id] = "应用不可用，请重新选择。"; return }
        launching.insert(app.id)
        let token = generation
        launch(url) { [weak self] error in
            guard let self, token == self.generation else { return }
            self.launching.remove(app.id)
            if let error { self.issues[app.id] = "打开失败：" + error }
            else { self.issues[app.id] = self.registrationIssues[app.id] }
        }
    }
    private func apply() {
        // Keep already-consumed downs paired with their eventual key-up even
        // when this module is disabled or its recorder is entered mid-press.
        generation += 1; registry.unregisterAll(); mappedActions.removeAll(); launching.removeAll(); issues = [:]; registrationIssues = [:]
        guard configurationLoaded else { status = "等待重新连接原有配置。"; return }
        guard !suspended, allEnabled else { status = "全部增强已停用。"; return }
        guard configuration.enabled else { status = "未开启应用快捷键。"; return }
        guard !recording, !inputRecording else { status = "正在录制，应用快捷键暂时停用。"; return }
        var registered = 0
        for app in configuration.apps where app.enabled {
            guard app.shortcut.keyCode != nil else { issues[app.id] = "尚未设置快捷键"; continue }
            guard resolve(app) != nil else { issues[app.id] = "应用不可用，请重新选择。"; continue }
            let token = generation
            let action: () -> Void = { [weak self] in
                guard let self, token == self.generation else { return }
                self.onHotKeyActivation?()
                self.toggle(app)
            }
            if let error = registry.register(app.shortcut, action: action) { issues[app.id] = error }
            else {
                registered += 1
                mappedActions[Self.chord(app.shortcut.keyCode!, app.shortcut.modifiers)] = action
            }
        }
        registrationIssues = issues
        status = "已启用 \(registered) 个应用快捷键" + (issues.isEmpty ? "。" : "，\(issues.count) 项需要处理。")
    }
}
