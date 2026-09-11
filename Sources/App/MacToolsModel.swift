import AppKit
import Combine

@MainActor
final class MacToolsModel: ObservableObject {
    @Published private(set) var configuration = MacToolsConfiguration()
    @Published var errorMessage: String?
    @Published private(set) var configurationLoaded = false
    @Published var recording = false { didSet { scheduleApply() } }
    let updates = AppUpdateModel()
    private var suspendedForUpdate = false
    let input = InputRuntime()
    let appShortcuts = AppShortcutModel()
    private let standalone: StandaloneMenuController
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    init(standalone: StandaloneMenuController) {
        self.standalone = standalone
        input.mappedShortcutHandler = { [weak self] type, event, active in
            self?.appShortcuts.handleMappedKey(type, event, mappingActive: active) ?? false
        }
        appShortcuts.onHotKeyActivation = { [weak self] in self?.input.markMappedCombinationUsed() }
        do { configuration = try MacToolsConfigurationStore.load(); configurationLoaded = true }
        catch { configuration.allEnabled = false; errorMessage = "无法读取 MacTools 配置：\(error.localizedDescription)" }
        input.recover()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    func update(_ change: (inout MacToolsConfiguration) -> Void) {
        guard configurationLoaded else {
            errorMessage = "原配置尚未读取，已阻止保存默认设置。请先在应用设置中重新连接配置。"
            return
        }
        var next = configuration
        change(&next)
        do {
            try MacToolsConfigurationStore.save(next)
            let disabled = (configuration.finderActive && !next.finderActive)
                || (configuration.mouseActive && !next.mouseActive) || (configuration.hyperActive && !next.hyperActive)
            configuration = next
            // Disables take effect synchronously; only parameter editing debounces.
            if disabled || !next.allEnabled { refresh() }
            else { scheduleApply() }
        } catch { errorMessage = error.localizedDescription }
    }
    private func scheduleApply() {
        guard !suspendedForUpdate else { return }
        pending?.cancel()
        if recording { appShortcuts.setContext(allEnabled: configuration.allEnabled, inputRecording: true); input.stop(); return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func refresh() {
        guard !suspendedForUpdate else { return }
        pending?.cancel()
        standalone.refresh()
        appShortcuts.stop()
        input.apply(configuration, recording: recording)
        appShortcuts.setContext(allEnabled: configuration.allEnabled, inputRecording: recording)
    }
    func reconnectConfiguration() {
        do {
            guard try SharedConfigurationAccess.reconnect() else { return }
            configuration = try MacToolsConfigurationStore.load()
            configurationLoaded = true
            errorMessage = nil
            appShortcuts.reloadConfiguration()
            refresh()
        } catch { errorMessage = "无法重新连接配置：" + error.localizedDescription }
    }
    func suspendForUpdate() { suspendedForUpdate = true; stop() }
    func resumeAfterUpdate() { suspendedForUpdate = false; refresh() }
    func stop() { pending?.cancel(); appShortcuts.stop(); input.stop(); standalone.stop() }
}
