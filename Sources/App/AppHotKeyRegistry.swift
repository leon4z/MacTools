import AppKit
import Carbon

@MainActor protocol AppHotKeyRegistering: AnyObject {
    func register(_ shortcut: TapShortcut, action: @escaping () -> Void) -> String?
    func unregisterAll()
}

/// Uses the Carbon hot-key mechanism used by Thor/MASShortcut and HotKey.
/// Registers only chosen combinations; does not install another input event tap.
@MainActor final class AppHotKeyRegistry: AppHotKeyRegistering {
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var pressed = Set<UInt32>()
    private var nextID: UInt32 = 1
    private static let signature: UInt32 = 0x4D544150 // MTAP

    deinit {
        for reference in references { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func carbonModifiers(_ flags: UInt64) -> UInt32 {
        var result: UInt32 = 0
        if flags & CGEventFlags.maskCommand.rawValue != 0 { result |= UInt32(cmdKey) }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { result |= UInt32(optionKey) }
        if flags & CGEventFlags.maskControl.rawValue != 0 { result |= UInt32(controlKey) }
        if flags & CGEventFlags.maskShift.rawValue != 0 { result |= UInt32(shiftKey) }
        return result
    }
    private func installHandler() -> Bool {
        if handler != nil { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        return InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<AppHotKeyRegistry>.fromOpaque(context).takeUnretainedValue()
                return owner.receive(event)
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }
    private func receive(_ event: EventRef) -> OSStatus {
        var hotKey = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &hotKey) == noErr,
              hotKey.signature == Self.signature, let action = actions[hotKey.id] else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { pressed.remove(hotKey.id) }
        else if pressed.insert(hotKey.id).inserted { action() }
        return noErr
    }
    func register(_ shortcut: TapShortcut, action: @escaping () -> Void) -> String? {
        guard let code = shortcut.keyCode else { return "尚未设置快捷键" }
        let modifiers = Self.carbonModifiers(shortcut.modifiers)
        // This fixed system command is also used to dispatch the lock action.
        // Keep it out of our registry even when CopySymbolicHotKeys omits it.
        if code == 12 && modifiers == UInt32(controlKey | cmdKey) {
            return "⌃⌘Q 是 macOS 锁屏快捷键，请选择其他组合。"
        }
        // Mouse zoom emits these commands. Carbon does not expose the CGEvent
        // marker, so reserve the pair to prevent a synthetic zoom firing an action.
        if (code == 69 || code == 78) && modifiers == UInt32(cmdKey) {
            return "⌘小键盘＋／－用于鼠标缩放，请选择其他组合。"
        }
        var symbolic: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolic) == noErr, let keys = symbolic?.takeRetainedValue() as? [[String: Any]],
           keys.contains(where: { ($0[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true
               && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value == code
               && ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == modifiers }) {
            return "与 macOS 系统快捷键冲突，请换一个组合。"
        }
        guard installHandler() else { return "无法启动快捷键监听。" }
        guard nextID < UInt32.max else { return "请重启 MacTools 后重试。" }
        let id = nextID; nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return "快捷键注册失败（\(status)），可能已被 Thor 或其他应用占用。" }
        references.append(reference); actions[id] = action
        return nil
    }
    func unregisterAll() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll(); actions.removeAll(); pressed.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
