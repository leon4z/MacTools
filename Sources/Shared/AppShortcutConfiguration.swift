import Foundation

struct AppShortcut: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var bundleIdentifier: String
    var applicationPath: String
    var shortcut = TapShortcut()
    var enabled = true
}

enum SystemShortcutCategory: String, CaseIterable, Identifiable {
    case capture = "截图与录屏", windows = "桌面与窗口", sound = "声音", media = "媒体控制"
    case input = "输入与搜索", display = "显示与电源", custom = "自定义"
    var id: Self { self }
}

enum SystemShortcutAction: String, Codable, CaseIterable, Identifiable {
    case lockScreen, screenshotRegion, screenshotFull, screenshotToolbar
    case showDesktop, missionControl, previousSpace, nextSpace, toggleFullScreen
    case volumeUp, volumeDown, mute, playPause, previousTrack, nextTrack
    case switchInputSource, emojiPicker, spotlight, brightnessUp, brightnessDown
    case displaySleep, systemSleep, sendShortcut
    var id: Self { self }
    var category: SystemShortcutCategory {
        switch self {
        case .screenshotRegion, .screenshotFull, .screenshotToolbar: return .capture
        case .showDesktop, .missionControl, .previousSpace, .nextSpace, .toggleFullScreen: return .windows
        case .volumeUp, .volumeDown, .mute: return .sound
        case .playPause, .previousTrack, .nextTrack: return .media
        case .switchInputSource, .emojiPicker, .spotlight: return .input
        case .lockScreen, .brightnessUp, .brightnessDown, .displaySleep, .systemSleep: return .display
        case .sendShortcut: return .custom
        }
    }
    var title: String {
        switch self {
        case .lockScreen: return "锁定屏幕"
        case .screenshotRegion: return "区域截图"
        case .screenshotFull: return "全屏截图"
        case .screenshotToolbar: return "截图／录屏工具栏"
        case .showDesktop: return "显示／隐藏桌面"
        case .missionControl: return "调度中心"
        case .previousSpace: return "切换到左侧桌面"
        case .nextSpace: return "切换到右侧桌面"
        case .toggleFullScreen: return "切换全屏"
        case .volumeUp: return "调高音量"
        case .volumeDown: return "调低音量"
        case .mute: return "静音／取消静音"
        case .playPause: return "播放／暂停"
        case .previousTrack: return "上一首"
        case .nextTrack: return "下一首"
        case .switchInputSource: return "切换输入法"
        case .emojiPicker: return "表情符号与符号"
        case .spotlight: return "聚焦搜索"
        case .brightnessUp: return "调高亮度"
        case .brightnessDown: return "调低亮度"
        case .displaySleep: return "关闭显示器"
        case .systemSleep: return "系统睡眠"
        case .sendShortcut: return "发送自定义组合键"
        }
    }
    var icon: String {
        switch category {
        case .capture: return "camera.viewfinder"
        case .windows: return "macwindow"
        case .sound: return "speaker.wave.2"
        case .media: return "playpause"
        case .input: return "character.cursor.ibeam"
        case .display: return self == .lockScreen ? "lock.display" : "display"
        case .custom: return "keyboard"
        }
    }
    var detail: String {
        switch self {
        case .lockScreen: return "立即锁屏，解锁后继续使用当前应用。"
        case .screenshotRegion: return "发送系统默认 ⌘⇧4，选择截图区域；保存位置沿用系统设置。"
        case .screenshotFull: return "发送系统默认 ⌘⇧3，截取整个屏幕；保存位置沿用系统设置。"
        case .screenshotToolbar: return "打开系统工具栏，选择截图或录屏范围。"
        case .showDesktop: return "发送系统默认 F11，暂时移开窗口，再次执行恢复；需启用对应系统快捷键。"
        case .missionControl: return "总览当前打开的窗口和桌面空间。"
        case .previousSpace, .nextSpace: return "发送系统默认 ⌃←／⌃→，切换相邻桌面；需启用对应系统快捷键。"
        case .toggleFullScreen: return "发送 ⌃⌘F，进入或退出当前应用的全屏模式，需要应用支持。"
        case .volumeUp, .volumeDown, .mute: return "控制当前音频输出；设备需支持系统音量调节。"
        case .playPause, .previousTrack, .nextTrack: return "控制系统当前媒体播放器，需要播放器支持媒体键。"
        case .switchInputSource: return "在已启用、可选择的键盘输入法之间轮换。"
        case .emojiPicker: return "发送系统默认 ⌃⌘Space，在当前应用中打开字符检视器。"
        case .spotlight: return "打开系统聚焦搜索。"
        case .brightnessUp, .brightnessDown: return "调整支持系统亮度控制的显示器；部分外接显示器不支持。"
        case .displaySleep: return "立即关闭显示器，后台任务继续；不等同于锁屏。"
        case .systemSleep: return "立即请求整机睡眠，会暂停当前工作和连接。"
        case .sendShortcut: return "向当前应用发送下面的组合键，不可指向 MacTools 已启用的其他绑定。"
        }
    }
}

struct SystemShortcut: Codable, Equatable, Identifiable {
    var id = UUID()
    var action: SystemShortcutAction = .lockScreen
    var targetShortcut: TapShortcut?
    var shortcut = TapShortcut()
    var enabled = true
}

struct AppShortcutConfiguration: Codable, Equatable {
    var version = 2
    var enabled = false
    var apps: [AppShortcut] = []
    var systemActions: [SystemShortcut] = []

    init() {}
    private enum CodingKeys: String, CodingKey { case version, enabled, apps, systemActions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == 2 else { throw AppShortcutError.message("不支持此快捷键配置版本。") }
        enabled = try values.decode(Bool.self, forKey: .enabled)
        apps = try values.decode([AppShortcut].self, forKey: .apps)
        // v1 contained only application shortcuts. Upgrade in memory; saving is explicit.
        systemActions = storedVersion == 1 ? [] : try values.decode([SystemShortcut].self, forKey: .systemActions)
    }
    func validate() throws {
        let ids = apps.map(\.id) + systemActions.map(\.id)
        guard version == 2, ids.count <= 100, Set(ids).count == ids.count else { throw AppShortcutError.message("快捷键配置无效。") }
        var chords = Set<String>()
        for app in apps {
            guard !app.name.isEmpty, !app.bundleIdentifier.isEmpty, app.applicationPath.hasPrefix("/"), app.applicationPath.lowercased().hasSuffix(".app") else { throw AppShortcutError.message("请选择有效的应用。") }
        }
        let bindings = apps.map { ($0.shortcut, $0.enabled) } + systemActions.map { ($0.shortcut, $0.enabled) }
        for (shortcut, enabled) in bindings {
            guard let code = shortcut.keyCode else { continue }
            let allowed: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
            let required: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
            guard code <= 127, ![54,55,56,57,58,59,60,61,62,63,79].contains(code),
                  shortcut.modifiers & required != 0, shortcut.modifiers & ~allowed == 0 else {
                throw AppShortcutError.message("快捷键需要 ⌘、⌥ 或 ⌃ 搭配普通按键；F18 保留给 Caps Lock 映射。")
            }
            if enabled && !chords.insert("\(code):\(shortcut.modifiers)").inserted {
                throw AppShortcutError.message("这个快捷键已分配给其他应用或系统操作，请换一个组合。")
            }
        }
        for item in systemActions where item.action == .sendShortcut {
            guard let target = item.targetShortcut, let code = target.keyCode else { continue }
            let allowed: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
            guard code <= 127, ![54,55,56,57,58,59,60,61,62,63,79].contains(code), target.modifiers & ~allowed == 0 else {
                throw AppShortcutError.message("输出组合键需包含普通按键；不支持单独的辅助键、Caps Lock、Fn 或保留的 F18。")
            }
            if item.enabled && chords.contains("\(code):\(target.modifiers)") {
                throw AppShortcutError.message("输出组合键与 MacTools 已启用的绑定重复，会循环触发；请更换组合键。")
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
