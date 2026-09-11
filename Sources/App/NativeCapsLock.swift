import Foundation
import IOKit
import IOKit.hidsystem

/// Changes the system lock (including keyboard LEDs), not a synthetic Shift press.
/// Caps Lock is user state: do not undo it when Hyper/Meh stops or restarts.
enum NativeCapsLock {
    static func toggle() throws {
        try withConnection { connection in
            let current = try read(connection)
            try check(IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !current))
            guard try read(connection) == !current else {
                throw failure("系统未接受大写锁定切换。")
            }
        }
    }

    private static func read(_ connection: io_connect_t) throws -> Bool {
        var state = false
        try check(IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state))
        return state
    }

    private static func withConnection(_ body: (io_connect_t) throws -> Void) throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { throw failure("无法连接系统键盘。") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        try check(IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection))
        defer { IOServiceClose(connection) }
        try body(connection)
    }

    private static func check(_ result: kern_return_t) throws {
        guard result == KERN_SUCCESS else {
            throw failure("无法切换系统大写锁定（错误 \(result)）。")
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MacTools.CapsLock", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
