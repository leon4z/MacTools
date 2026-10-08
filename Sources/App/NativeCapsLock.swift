import Foundation
import IOKit

/// Read and write the same keyboard service state, which also drives its LED.
/// IOHIDGetModifierLockState reads a separate legacy state that can disagree.
/// Caps Lock is user state: do not undo it when Hyper/Meh stops or restarts.
enum NativeCapsLock {
    struct Keyboard {
        let read: () -> Bool?
        let write: (Bool) -> Bool
    }

    static func toggle() throws {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault),
              let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            throw failure("无法连接系统键盘。")
        }
        let keyboards = services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }.map { service in
            Keyboard(read: {
                IOHIDServiceClientCopyProperty(service, "HIDCapsLockState" as CFString) as? Bool
            }, write: { enabled in
                IOHIDServiceClientSetProperty(service, "HIDCapsLockState" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
            })
        }
        try withExtendedLifetime(client) { try toggle(keyboards: keyboards) }
    }

    static func toggle(keyboards: [Keyboard]) throws {
        guard !keyboards.isEmpty else { throw failure("未检测到可配置键盘。") }
        // Snapshot every device before writing. If states differ, one tap clears
        // Caps Lock on all keyboards; the next tap enables it on all keyboards.
        let states = try keyboards.map { keyboard in
            guard let state = keyboard.read() else { throw failure("无法读取键盘大写锁定状态。") }
            return state
        }
        let target = !states.contains(true)
        for keyboard in keyboards {
            guard keyboard.write(target) else { throw failure("系统未接受大写锁定切换。") }
        }
        guard keyboards.allSatisfy({ $0.read() == target }) else {
            throw failure("系统未接受大写锁定切换。")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MacTools.CapsLock", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
