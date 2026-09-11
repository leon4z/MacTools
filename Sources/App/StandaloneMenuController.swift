import AppKit
import ApplicationServices
import Combine

@MainActor
final class StandaloneMenuController: NSObject, ObservableObject {
    enum Action { case copy, move, newFile, open(String) }
    @Published private(set) var enabled: Bool
    @Published private(set) var trigger: StandaloneMenuTrigger
    @Published private(set) var status = "未开启"
    @Published private(set) var trusted = false
    private let defaults: UserDefaults
    private let perform: (Action, StandaloneMenuContext) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = StandaloneMenuGesture()
    private var downPoint: CGPoint?
    private var downPID: pid_t?
    private var downTime: TimeInterval = 0
    private struct WindowIdentity: Equatable { let id: Int; let bounds: CGRect }
    private var downWindow: WindowIdentity?
    private var pendingResult: Result<StandaloneMenuContext, Error>?
    private var released = false
    private var cancelled = false
    private var busy = false
    private var generation = 0
    private var activeMenu: NSMenu?
    private var commands: [Int: Action] = [:]
    private var chosenAction: Action?
    private let captureQueue = DispatchQueue(label: "local.leon.FinderRightClick.context", qos: .userInitiated)

    init(defaults: UserDefaults = .standard, perform: @escaping (Action, StandaloneMenuContext) -> Void) {
        self.defaults = defaults
        self.perform = perform
        enabled = defaults.bool(forKey: "StandaloneMenu.enabled")
        trigger = StandaloneMenuTrigger(rawValue: defaults.string(forKey: "StandaloneMenu.trigger") ?? "") ?? .option
        super.init()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "StandaloneMenu.enabled")
        refresh()
    }
    func setTrigger(_ value: StandaloneMenuTrigger) {
        trigger = value
        defaults.set(value.rawValue, forKey: "StandaloneMenu.trigger")
        refresh()
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
    func refresh() {
        stop()
        trusted = AXIsProcessTrusted()
        guard MacToolsConfigurationStore.finderActive else { status = "访达右键增强已停用，请在应用设置中开启。"; return }
        guard enabled else { status = "未开启"; return }
        guard trusted else { status = "等待辅助功能授权，授权后点击“重新检查”"; return }
        let mask = (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDragged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                // This tap is attached exclusively to the main run loop.
                return MainActor.assumeIsolated {
                    Unmanaged<StandaloneMenuController>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = "无法监听鼠标。请检查辅助功能权限，然后重新检查。"
            return
        }
        tap = eventTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let source else { stop(); status = "无法启动鼠标监听"; return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        status = "已开启：在访达内容区域使用\(trigger.title)"
    }

    func stop() {
        generation += 1
        activeMenu?.cancelTracking()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        gesture.reset()
        downPoint = nil
        downPID = nil
        downWindow = nil
        pendingResult = nil
        released = false
        cancelled = true
        busy = false
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gesture.reset()
            downPoint = nil
            cancelled = true
            pendingResult = nil
            busy = false
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if busy && activeMenu == nil && [.leftMouseDown, .otherMouseDown, .scrollWheel, .rightMouseDragged].contains(type) {
            cancelled = true
            pendingResult = nil
            // Keep the gesture pair claimed until its rightMouseUp arrives.
            if !gesture.pressed { busy = false }
        }
        if type == .rightMouseDown {
            if busy, activeMenu == nil, !gesture.pressed {
                cancelled = true
                pendingResult = nil
                busy = false
            }
            let flags = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
            let expected: CGEventFlags = trigger == .option ? .maskAlternate : .maskCommand
            let front = NSWorkspace.shared.frontmostApplication
            let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
            let isFinder = front?.bundleIdentifier == "com.apple.finder"
                && (targetPID == 0 || targetPID == Int64(front!.processIdentifier))
            guard enabled, flags == expected, isFinder, !busy,
                  let pid = front?.processIdentifier,
                  let window = windowIdentity(at: event.location, finderPID: pid) else { return Unmanaged.passUnretained(event) }
            if gesture.down(matches: true, isFinder: true, busy: false) == .consume {
                downPoint = event.location
                downPID = pid
                downWindow = window
                downTime = ProcessInfo.processInfo.systemUptime
                pendingResult = nil
                released = false
                cancelled = false
                busy = true
                // Capture immediately on down; mouse-up only authorizes showing
                // the frozen result. No AX query occurs on this event callback.
                capture(point: event.location, pid: pid, token: generation, requested: downTime)
                return nil
            }
        } else if type == .rightMouseUp, gesture.up() == .invoke {
            released = true
            if let point = downPoint {
                cancelled = cancelled || ProcessInfo.processInfo.systemUptime - downTime >= 1.5
                    || hypot(event.location.x - point.x, event.location.y - point.y) >= 8
            }
            if cancelled { busy = false; pendingResult = nil }
            else { DispatchQueue.main.async { [weak self] in self?.finishPending() } }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func capture(point: CGPoint, pid: pid_t, token: Int, requested: TimeInterval) {
        captureQueue.async { [weak self] in
            // Reject queued/stale reads before doing any hit test.
            guard ProcessInfo.processInfo.systemUptime - requested < 0.15 else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, token == self.generation, requested == self.downTime else { return }
                    self.cancelled = true
                    if self.released { self.busy = false }
                }
                return
            }
            let result = Result { try FinderAccessibilityContext.capture(at: point, finderPID: pid) }
            DispatchQueue.main.async {
                guard let self, token == self.generation, requested == self.downTime else { return }
                guard self.enabled, !self.cancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      ProcessInfo.processInfo.systemUptime - requested < 1.0,
                      self.windowIdentity(at: point, finderPID: pid) == self.downWindow else {
                    self.cancelled = true
                    if self.released { self.busy = false }
                    return
                }
                self.pendingResult = result
                self.finishPending()
            }
        }
    }

    private func finishPending() {
        guard released, !cancelled, let result = pendingResult,
              let point = downPoint, let pid = downPID else { return }
        pendingResult = nil
        defer { busy = false; downPoint = nil; downPID = nil; downWindow = nil }
        guard enabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              ProcessInfo.processInfo.systemUptime - downTime < 1.5,
              windowIdentity(at: point, finderPID: pid) == downWindow else { return }
        switch result {
        case .success(let context): show(context, at: point)
        case .failure(let error): showUnavailable(error.localizedDescription, at: point)
        }
    }

    /// Window IDs and geometry require no title/content capture. Reject clicks
    /// into a different window or a window that moved while AX was being read.
    private func windowIdentity(at point: CGPoint, finderPID: pid_t) -> WindowIdentity? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary), bounds.contains(point),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(finderPID),
                  let id = window[kCGWindowNumber as String] as? Int else { return nil }
            return WindowIdentity(id: id, bounds: bounds)
        }
        return nil
    }

    private func show(_ context: StandaloneMenuContext, at point: CGPoint) {
        status = "已开启：在访达内容区域使用\(trigger.title)"
        let menu = NSMenu(title: "MacTools")
        menu.autoenablesItems = false
        commands.removeAll()
        chosenAction = nil
        func add(_ title: String, _ action: Action, to destination: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = commands.count + 1
            commands[item.tag] = action
            destination.addItem(item)
        }
        add(context.targets.count > 1 ? "拷贝路径 (\(context.targets.count) 项)" : "拷贝路径", .copy, to: menu)
        if !context.isBackground { add("移动到…", .move, to: menu) }
        if context.newFileDirectory != nil { add("新建文件", .newFile, to: menu) }
        if context.targets.count == 1 {
            let tools = ToolCatalog.resolvedAvailableTools()
            if !tools.isEmpty {
                let item = NSMenuItem(title: "用工具打开", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "用工具打开")
                for tool in tools { add(tool.tool.name, .open(tool.tool.id), to: submenu) }
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        popup(menu, at: point)
        // Defer dialogs and workspace activation until menu tracking has ended.
        if let chosenAction, enabled, MacToolsConfigurationStore.finderActive { perform(chosenAction, context) }
        commands.removeAll()
        chosenAction = nil
    }
    private func showUnavailable(_ message: String, at point: CGPoint) {
        let menu = NSMenu(title: "MacTools")
        let item = NSMenuItem(title: "无法识别当前目标", action: nil, keyEquivalent: "")
        item.toolTip = message
        item.isEnabled = false
        menu.addItem(item)
        status = message
        popup(menu, at: point)
    }
    private func popup(_ menu: NSMenu, at point: CGPoint) {
        activeMenu = menu
        // CG/AX coordinates are top-left relative to the primary display.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: primaryHeight - point.y), in: nil)
        activeMenu = nil
    }
    @objc private func choose(_ item: NSMenuItem) { chosenAction = commands[item.tag] }
}
