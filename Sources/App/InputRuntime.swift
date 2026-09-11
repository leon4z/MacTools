import AppKit
import ApplicationServices
import Combine
import IOKit
import os

@MainActor
final class InputRuntime: ObservableObject {
    @Published private(set) var trusted = false
    @Published private(set) var mouseStatus = "未开启。在应用设置中启用鼠标工具。"
    @Published private(set) var hyperStatus = "未开启。在应用设置中启用 Hyperkey。"
    @Published private(set) var devices: [String] = []
    var mappedShortcutHandler: ((CGEventType, CGEvent, Bool) -> Bool)?
    private var configuration = MacToolsConfiguration()
    private let caps = CapsLockLease()
    private let pointer = HIDSettingsLease(name: "pointer")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var healthTimer: Timer?
    private let mouseScroll = MouseScrollRuntime()
    private var state = HyperState()
    private var hyperRunning = false
    private var mouseRunning = false
    private var deviceIDs = Set<String>()
    private var pointerRecoveryError: String?
    private var keyboardRecoveryError: String?
    private var pointerRunning = false
    private var generation = 0
    private static let marker: Int64 = 0x4D6163546F6F6C73

    func markMappedCombinationUsed() { state.markUsed() }

    func recover() {
        do { try caps.lease.recover(); keyboardRecoveryError = nil }
        catch { keyboardRecoveryError = error.localizedDescription }
        do { try pointer.recover(); pointerRecoveryError = nil }
        catch { pointerRecoveryError = error.localizedDescription }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func apply(_ configuration: MacToolsConfiguration, recording: Bool = false) {
        defer {
            Logger(subsystem: "com.leon4z.MacTools", category: "InputRuntime").notice(
                "Input status: mouse=\(self.mouseStatus, privacy: .public); hyper=\(self.hyperStatus, privacy: .public)")
        }
        stop()
        recover()
        self.configuration = configuration
        trusted = AXIsProcessTrusted()
        devices = Array(Set(pointer.mice.map { pointer.name($0) })).sorted()
        mouseStatus = "未开启。在应用设置中启用鼠标工具。"
        hyperStatus = "未开启。在应用设置中启用 Hyperkey。"
        guard configuration.allEnabled else { mouseStatus = "全部增强已停用。"; hyperStatus = mouseStatus; return }
        guard !recording else { hyperStatus = "正在录制快捷键，映射暂时停用。"; return }
        guard configuration.mouseActive || configuration.hyperActive else { return }
        guard trusted else {
            if configuration.mouseActive { mouseStatus = "等待辅助功能授权，请前往应用设置。" }
            if configuration.hyperActive { hyperStatus = "等待辅助功能授权，请前往应用设置。" }
            return
        }
        let runningNames = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() })
        mouseRunning = configuration.mouseActive
        hyperRunning = configuration.hyperActive && (configuration.hyper.hyper.enabled || configuration.hyper.meh.enabled)
        if mouseRunning && runningNames.contains("bettermouse") {
            mouseRunning = false
            mouseStatus = "检测到 BetterMouse 正在运行。请先退出它，再点击应用设置中的重新检查。"
        }
        if hyperRunning && (runningNames.contains("superkey") || runningNames.contains("hyperkey")) {
            hyperRunning = false
            hyperStatus = "检测到 Superkey / Hyperkey 正在运行。请先退出它，再重新检查。"
        }
        if configuration.hyperActive && !configuration.hyper.hyper.enabled && !configuration.hyper.meh.enabled {
            hyperStatus = "模块已开启，请启用下方 Hyper 或 Meh 映射。"
        }
        guard mouseRunning || hyperRunning else { return }
        if hyperRunning {
        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    Unmanaged<InputRuntime>.fromOpaque(userInfo).takeUnretainedValue().receive(type, event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                mouseStatus = "无法启动输入监听，请重新检查辅助功能授权。"
                hyperStatus = mouseStatus; mouseRunning = false; hyperRunning = false; return
        }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: newTap, enable: true)
        }
        if hyperRunning, let keyboardRecoveryError {
            hyperRunning = false
            hyperStatus = "键盘映射已暂停：" + keyboardRecoveryError
        }
        if hyperRunning {
            do {
                if mappings.contains(where: { $0.enabled && $0.trigger == .capsLock }) { try caps.enable() }
                hyperStatus = "映射已运行。单击执行映射，组合使用后松开不触发单击。"
            } catch {
                hyperRunning = false
                do { try caps.lease.restore() } catch { keyboardRecoveryError = error.localizedDescription }
                hyperStatus = error.localizedDescription
            }
        }
        if mouseRunning {
            mouseScroll.onFailure = { [weak self] in
                self?.mouseStatus = "滚动监听被系统暂停，已恢复原生滚动；请重新检查。"
            }
            guard mouseScroll.start(configuration.mouse) else {
                mouseRunning = false
                mouseStatus = "滚动监听启动失败，原生滚动保持可用。请重新检查辅助功能权限。"
                return
            }
            if configuration.mouse.pointer && pointerRecoveryError == nil {
                do { try applyPointer(); pointerRunning = true }
                catch {
                    let setupError = error.localizedDescription
                    do { try pointer.restore() }
                    catch { pointerRecoveryError = error.localizedDescription }
                    pointerRecoveryError = pointerRecoveryError ?? setupError
                }
            }
            if let pointerRecoveryError {
                mouseStatus = (configuration.mouse.scrolling ? "滚动处理已运行。" : "滚动处理未开启。")
                    + "指针调整已暂停：" + pointerRecoveryError
            } else {
                mouseStatus = "鼠标工具已运行。参数更改自动生效。"
            }
        }
        deviceIDs = Set(pointer.services.map { pointer.id($0) })
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private var mappings: [ModifierMapping] { [configuration.hyper.hyper, configuration.hyper.meh] }
    private func applyPointer() throws {
        let mice = pointer.mice
        guard !mice.isEmpty else { throw HIDFailure.message("没有可调整的鼠标设备。") }
        let p = configuration.mouse
        // Full HID clients expose these values; validate the complete set before
        // leasing any property, instead of inventing a 400-DPI recovery value.
        let targets = try mice.map { service -> (IOHIDServiceClient, String, NSNumber, NSNumber, NSNumber) in
            let type = pointer.property(service, "HIDPointerAccelerationType") as? String ?? "HIDMouseAcceleration"
            guard type == "HIDMouseAcceleration" || type == "HIDPointerAcceleration",
                  let acceleration = pointer.property(service, type) as? NSNumber,
                  let resolution = pointer.property(service, "HIDPointerResolution") as? NSNumber,
                  resolution.doubleValue > 0,
                  let linear = pointer.property(service, "HIDUseLinearScalingMouseAcceleration") as? NSNumber else {
                throw HIDFailure.message("\(pointer.name(service)) 未提供可恢复的鼠标参数。滚动功能仍可使用。")
            }
            return (service, type, acceleration, resolution, linear)
        }
        for (service, type, originalAcceleration, originalResolution, originalLinear) in targets {
            // LinearMouse/PointerKit order: choose linear mode, set resolution
            // for accelerated mode, then refresh acceleration on that service.
            try pointer.set(service, key: "HIDUseLinearScalingMouseAcceleration", value: p.pointerAcceleration < 0, missingDefault: originalLinear)
            if p.pointerAcceleration >= 0 {
                let resolution = (originalResolution.doubleValue / p.pointerSpeed).clamped(to: 1...Double(Int32.max))
                try pointer.set(service, key: "HIDPointerResolution", value: NSNumber(value: Int(resolution)), missingDefault: originalResolution)
            }
            let acceleration = p.pointerAcceleration < 0 ? p.pointerSpeed : p.pointerAcceleration
            try pointer.set(service, key: type, value: NSNumber(value: Int(acceleration * 65536)), missingDefault: originalAcceleration, force: true)
        }
    }

    func stop() {
        generation += 1
        healthTimer?.invalidate(); healthTimer = nil
        mouseScroll.stop()
        let hadModifiers = !state.pressed.isEmpty
        state.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if hadModifiers { postModifierRelease() }
        hyperRunning = false; mouseRunning = false; pointerRunning = false
        do { try caps.lease.restore(); keyboardRecoveryError = nil }
        catch { keyboardRecoveryError = error.localizedDescription; hyperStatus = error.localizedDescription }
        do { try pointer.restore(); pointerRecoveryError = nil }
        catch { pointerRecoveryError = error.localizedDescription; mouseStatus = error.localizedDescription }
    }
    private func checkHealth() {
        guard AXIsProcessTrusted() else {
            stop(); mouseStatus = "辅助功能权限发生变化，已暂停；请重新检查。"; hyperStatus = mouseStatus; return
        }
        // Preserve external ownership and stop only the affected subsystem.
        if hyperRunning && !caps.lease.ownershipIntact {
            generation += 1
            let held = !state.pressed.isEmpty
            state.reset()
            if held { postModifierRelease() }
            hyperRunning = false
            do { try caps.lease.restore() } catch { keyboardRecoveryError = error.localizedDescription }
            hyperStatus = "键盘参数发生外部变化，映射已暂停；请重新检查。"
        }
        if pointerRunning && !pointer.ownershipIntact {
            pointerRunning = false
            do { try pointer.restore() } catch { pointerRecoveryError = error.localizedDescription }
            mouseStatus = (configuration.mouse.scrolling ? "滚动处理已运行。" : "滚动处理未开启。")
                + "指针参数发生外部变化，指针调整已暂停；请重新检查。"
        }
        let ids = Set(pointer.services.map { pointer.id($0) })
        if ids != deviceIDs { apply(configuration) }
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Do not auto-reenable a broken mapping while keys are held.
            DispatchQueue.main.async { [weak self] in
                self?.stop(); self?.hyperStatus = "输入监听被系统暂停，请重新检查。"; self?.mouseStatus = "输入监听被系统暂停，请重新检查。"
            }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return Unmanaged.passUnretained(event) }
        if hyperRunning {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if [.keyDown, .keyUp, .flagsChanged].contains(type), let mapping = mappings.first(where: { $0.enabled && $0.trigger.keyCode == code }) {
                let down = mapping.trigger == .capsLock ? type == .keyDown : event.flags.rawValue & mapping.trigger.deviceMask != 0
                if down {
                    let isHyper = mapping.trigger == configuration.hyper.hyper.trigger && configuration.hyper.hyper.enabled
                    var flags: CGEventFlags = [.maskControl, .maskAlternate]
                    if isHyper { flags.insert(.maskCommand); if configuration.hyper.includeShift { flags.insert(.maskShift) } }
                    else { flags.insert(.maskShift) }
                    state.down(mapping: mapping, flags: flags)
                } else {
                    let shortcut = state.up(code: code)
                    if let shortcut {
                        let token = generation
                        DispatchQueue.main.async { [weak self] in
                            guard let self, token == self.generation else { return }
                            self.postShortcut(shortcut)
                        }
                    }
                }
                event.type = .flagsChanged
                event.setIntegerValueField(.keyboardEventKeycode, value: 59)
                event.flags = state.outputFlags(raw: event.flags, mappings: mappings, apply: true)
                return Unmanaged.passUnretained(event)
            }
            let keyboard = [.keyDown, .keyUp, .flagsChanged].contains(type)
            let clicks = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type)
            let drags = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
            let apply = keyboard || (clicks && configuration.hyper.clicks) || (drags && configuration.hyper.drags)
                || (type == .mouseMoved && configuration.hyper.moves) || (type == .scrollWheel && configuration.hyper.scroll)
            if type == .keyDown || type == .flagsChanged || type == .scrollWheel || clicks || drags || (type == .mouseMoved && configuration.hyper.moves) { state.markUsed() }
            event.flags = state.outputFlags(raw: event.flags, mappings: mappings, apply: apply)
            if keyboard, mappedShortcutHandler?(type, event, !state.pressed.isEmpty) == true { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
    private func postShortcut(_ shortcut: TapShortcut) {
        guard hyperRunning else { return }
        if shortcut.keyCode == 57 {
            do { try NativeCapsLock.toggle() }
            catch { hyperStatus = "大写锁定切换失败：" + error.localizedDescription }
            return
        }
        let baseline = state.outputFlags(raw: CGEventSource.flagsState(.hidSystemState), mappings: mappings, apply: true)
        for event in TapShortcutEvents.make(shortcut, baseFlags: baseline, marker: Self.marker) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func postModifierRelease() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false) else { return }
        event.type = .flagsChanged
        event.flags = state.outputFlags(raw: CGEventSource.flagsState(.hidSystemState), mappings: mappings, apply: false)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}
