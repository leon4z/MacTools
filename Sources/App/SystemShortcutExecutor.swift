import AppKit
import Carbon
import IOKit.pwr_mgt

/// A resolved request is also used for output/trigger collision checks before dispatch.
enum SystemActionPlan: Equatable {
    case keyboard(TapShortcut)
    case mediaKey(Int)
    case openApplication(String)
    case switchInputSource, displaySleep, systemSleep

    var outputShortcut: TapShortcut? {
        if case .keyboard(let shortcut) = self { return shortcut }
        return nil
    }
}

@MainActor protocol SystemShortcutExecuting {
    func plan(for item: SystemShortcut) throws -> SystemActionPlan
    func execute(_ plan: SystemActionPlan, completion: @escaping (String?) -> Void)
}

@MainActor final class SystemShortcutExecutor: SystemShortcutExecuting {
    static let eventMarker: Int64 = 0x4D544C4F434B // Shared with the input tap: never remap our output.

    static func makePlan(for item: SystemShortcut) throws -> SystemActionPlan {
        func key(_ code: UInt16, _ flags: CGEventFlags, _ label: String) -> SystemActionPlan {
            .keyboard(TapShortcut(keyCode: code, label: label, modifiers: flags.rawValue))
        }
        switch item.action {
        case .lockScreen: return key(12, [.maskControl, .maskCommand], "⌃⌘Q")
        case .screenshotRegion: return key(21, [.maskCommand, .maskShift], "⌘⇧4")
        case .screenshotFull: return key(20, [.maskCommand, .maskShift], "⌘⇧3")
        case .screenshotToolbar: return .openApplication("com.apple.screenshot.launcher")
        case .showDesktop: return key(103, [], "F11")
        case .missionControl: return .openApplication("com.apple.exposelauncher")
        case .previousSpace: return key(123, .maskControl, "⌃←")
        case .nextSpace: return key(124, .maskControl, "⌃→")
        case .toggleFullScreen: return key(3, [.maskControl, .maskCommand], "⌃⌘F")
        case .emojiPicker: return key(49, [.maskControl, .maskCommand], "⌃⌘Space")
        case .spotlight: return .openApplication("com.apple.Spotlight")
        // NX_KEYTYPE_* from IOKit hidsystem/ev_keymap.h.
        case .volumeUp: return .mediaKey(0)
        case .volumeDown: return .mediaKey(1)
        case .brightnessUp: return .mediaKey(2)
        case .brightnessDown: return .mediaKey(3)
        case .mute: return .mediaKey(7)
        case .playPause: return .mediaKey(16)
        case .nextTrack: return .mediaKey(17)
        case .previousTrack: return .mediaKey(18)
        case .switchInputSource: return .switchInputSource
        case .displaySleep: return .displaySleep
        case .systemSleep: return .systemSleep
        case .sendShortcut:
            guard let target = item.targetShortcut, target.keyCode != nil else {
                throw AppShortcutError.message("尚未设置输出组合键")
            }
            return .keyboard(target)
        }
    }

    func plan(for item: SystemShortcut) throws -> SystemActionPlan {
        let plan = try Self.makePlan(for: item)
        switch plan {
        case .keyboard, .mediaKey:
            guard CGPreflightPostEventAccess() else {
                throw AppShortcutError.message("需要辅助功能授权，请在应用设置中授权后重新检查。")
            }
        case .openApplication(let identifier):
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil else {
                throw AppShortcutError.message("找不到对应的系统组件。")
            }
        case .switchInputSource:
            guard Self.inputSources().count > 1 else {
                throw AppShortcutError.message("请先在系统设置中启用至少两种键盘输入法。")
            }
        case .displaySleep:
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset") else {
                throw AppShortcutError.message("系统显示器睡眠工具不可用。")
            }
        case .systemSleep: break
        }
        return plan
    }

    func execute(_ plan: SystemActionPlan, completion: @escaping (String?) -> Void) {
        switch plan {
        case .keyboard(let shortcut):
            post(Self.keyboardEvents(shortcut, restoring: CGEventSource.flagsState(.hidSystemState)), completion: completion)
        case .mediaKey(let code):
            post(Self.mediaEvents(code, restoring: CGEventSource.flagsState(.hidSystemState)), completion: completion)
        case .openApplication(let identifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                completion("找不到对应的系统组件。"); return
            }
            let options = NSWorkspace.OpenConfiguration(); options.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: options) { _, error in
                DispatchQueue.main.async { completion(error.map { "打开系统组件失败：" + $0.localizedDescription }) }
            }
        case .switchInputSource:
            let sources = Self.inputSources()
            guard sources.count > 1 else { completion("请先启用至少两种键盘输入法。"); return }
            let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let index = sources.firstIndex { CFEqual($0, current) }
            let next = sources[((index ?? -1) + 1) % sources.count]
            let result = TISSelectInputSource(next)
            completion(result == noErr ? nil : "切换输入法失败（\(result)）。")
        case .displaySleep:
            // Fixed system tool and argument; never invoke a shell or request root.
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            process.terminationHandler = { process in
                let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let failed = process.terminationStatus != 0 || message.localizedCaseInsensitiveContains("error")
                    || message.localizedCaseInsensitiveContains("failed") || message.localizedCaseInsensitiveContains("must be")
                DispatchQueue.main.async {
                    completion(failed ? "关闭显示器失败：" + (message.isEmpty ? "系统拒绝请求。" : String(message.prefix(300))) : nil)
                }
            }
            do { try process.run() } catch { completion("无法关闭显示器：" + error.localizedDescription) }
        case .systemSleep:
            // Public API permits root OR the current console user.
            let port = IOPMFindPowerManagement(kIOMainPortDefault)
            guard port != 0 else { completion("无法连接系统电源管理服务。"); return }
            let result = IOPMSleepSystem(port)
            IOServiceClose(port)
            completion(result == kIOReturnSuccess ? nil : "系统拒绝睡眠请求（\(result)）。")
        }
    }

    private func post(_ events: [CGEvent], completion: (String?) -> Void) {
        guard CGPreflightPostEventAccess() else { completion("辅助功能权限不可用，请重新检查。"); return }
        guard !events.isEmpty else { completion("无法创建系统按键事件，请重试。"); return }
        // Build the whole pair before posting; held Hyper/Meh never leaks into output.
        for event in events { event.post(tap: .cghidEventTap) }
        completion(nil) // A dispatched request is not proof the target device/app handled it.
    }

    private static func inputSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!,
                      kTISPropertyInputSourceIsEnabled!: kCFBooleanTrue!,
                      kTISPropertyInputSourceIsSelectCapable!: kCFBooleanTrue!] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false) else { return [] }
        return list.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func lockEvents(restoring flags: CGEventFlags) -> [CGEvent] {
        keyboardEvents(TapShortcut(keyCode: 12, label: "⌃⌘Q", modifiers: CGEventFlags([.maskControl, .maskCommand]).rawValue), restoring: flags)
    }

    static func keyboardEvents(_ shortcut: TapShortcut, restoring flags: CGEventFlags) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        guard let code = shortcut.keyCode,
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false),
              let restore = restorationEvent(flags) else { return [] }
        down.flags = CGEventFlags(rawValue: shortcut.modifiers); up.flags = down.flags
        return marked([down, up, restore])
    }

    static func mediaEvents(_ code: Int, restoring flags: CGEventFlags) -> [CGEvent] {
        func event(_ down: Bool) -> CGEvent? {
            let state = down ? 0xA00 : 0xB00
            return NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)), timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | state, data2: -1)?.cgEvent
        }
        guard let down = event(true), let up = event(false), let restore = restorationEvent(flags) else { return [] }
        return marked([down, up, restore])
    }

    private static func restorationEvent(_ flags: CGEventFlags) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 59, keyDown: false) else { return nil }
        event.type = .flagsChanged; event.flags = flags
        return event
    }
    private static func marked(_ events: [CGEvent]) -> [CGEvent] {
        for event in events { event.setIntegerValueField(.eventSourceUserData, value: eventMarker) }
        return events
    }
}
