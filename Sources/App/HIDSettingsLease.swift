import Foundation
import IOKit

@MainActor protocol HIDSettingsLeasing: AnyObject {
    var services: [IOHIDServiceClient] { get }
    var keyboardServiceIDs: Set<String> { get }
    var mouseServiceIDs: Set<String> { get }
    var mice: [IOHIDServiceClient] { get }
    var keyboards: [IOHIDServiceClient] { get }
    var ownershipState: PropertyLeaseOwnership { get }
    func id(_ service: IOHIDServiceClient) -> String
    func property(_ service: IOHIDServiceClient, _ key: String) -> Any?
    func name(_ service: IOHIDServiceClient) -> String
    func set(_ service: IOHIDServiceClient, key: String, value: Any, missingDefault: Any, force: Bool) throws
    func refreshServices()
    func recover() throws
    func restore() throws
}

@MainActor protocol CapsLockLeasing: AnyObject {
    var lease: any HIDSettingsLeasing { get }
    func enable() throws
}

/// Own only the property values we wrote. Restore by compare-and-swap so that
/// another utility's later settings are never overwritten. Journal BEFORE write.
@MainActor
final class HIDSettingsLease: HIDSettingsLeasing {
    private var client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
    private let journalURL: URL
    private lazy var journal = PropertyLeaseJournal(url: journalURL, bootID: Self.bootID(),
        available: { [unowned self] in Set(self.services.map { self.id($0) }) },
        read: { [unowned self] sid, key in
            guard let service = self.services.first(where: { self.id($0) == sid }) else { return nil }
            return self.property(service, key)
        }, write: { [unowned self] sid, key, value in
            guard let service = self.services.first(where: { self.id($0) == sid }) else { return false }
            return IOHIDServiceClientSetProperty(service, key as CFString, value as CFTypeRef)
        })
    init(name: String) {
        journalURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/MacTools/\(name)-recovery.plist")
    }
    private static func bootID() -> String {
        func fallback() -> String {
            var boot = timeval()
            var length = MemoryLayout<timeval>.size
            if sysctlbyname("kern.boottime", &boot, &length, nil, 0) == 0 {
                return "boot-" + String(boot.tv_sec)
            }
            return "boot-" + String(Int((Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime).rounded()))
        }
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return fallback() }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return fallback() }
        return String(cString: buffer)
    }
    var services: [IOHIDServiceClient] {
        guard let client else { return [] }
        return IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
    }
    // A new connection provides a current inventory after wake/re-enumeration.
    // Journal closures intentionally resolve against this replaceable client.
    func refreshServices() { client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) }
    var keyboardServiceIDs: Set<String> { Set(keyboards.map { id($0) }) }
    var mouseServiceIDs: Set<String> { Set(mice.map { id($0) }) }
    func id(_ service: IOHIDServiceClient) -> String { String(describing: IOHIDServiceClientGetRegistryID(service)) }
    func property(_ service: IOHIDServiceClient, _ key: String) -> Any? { IOHIDServiceClientCopyProperty(service, key as CFString) }
    func name(_ service: IOHIDServiceClient) -> String { property(service, "Product") as? String ?? "鼠标设备" }
    var mice: [IOHIDServiceClient] {
        services.filter {
            IOHIDServiceClientConformsTo($0, 1, 2) != 0
                && IOHIDServiceClientConformsTo($0, 13, 5) == 0
                && !(property($0, "HIDPointerAccelerationType") as? String ?? "").contains("Trackpad")
                && !(name($0).localizedCaseInsensitiveContains("trackpad"))
        }
    }
    var keyboards: [IOHIDServiceClient] { services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 } }
    func set(_ service: IOHIDServiceClient, key: String, value: Any, missingDefault: Any, force: Bool = false) throws {
        try journal.set(id: id(service), key: key, value: value, missingDefault: missingDefault, force: force)
    }
    func recover() throws { try journal.recover() }
    func restore() throws { try journal.restore() }
    var ownershipIntact: Bool { journal.ownershipIntact }
    var ownershipState: PropertyLeaseOwnership { journal.ownershipState }

}

enum HIDFailure: LocalizedError {
    case message(String), conflict(String)
    var errorDescription: String? {
        switch self { case .message(let text), .conflict(let text): return text }
    }
}

/// Plans a reversible Caps Lock remap without changing any device.
enum CapsLockMapping {
    static let source: UInt64 = 0x700000039
    static let destination: UInt64 = 0x70000006d // F18
    static func replacingIdentity(in map: [[String: Any]]) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for item in map {
            let src = (item["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value
            let dst = (item["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value
            if src == dst && (src == source || src == destination) { continue }
            if src == source || src == destination || dst == destination {
                throw HIDFailure.conflict("Caps Lock 或 F18 已映射到其他按键，请先移除冲突映射，再重新检查。")
            }
            result.append(item)
        }
        result.append(["HIDKeyboardModifierMappingSrc": NSNumber(value: source), "HIDKeyboardModifierMappingDst": NSNumber(value: destination)])
        return result
    }
}

@MainActor
final class CapsLockLease: CapsLockLeasing {
    let lease: any HIDSettingsLeasing
    init(lease: (any HIDSettingsLeasing)? = nil) { self.lease = lease ?? HIDSettingsLease(name: "keyboard") }
    func enable() throws {
        let keyboards = lease.keyboards
        guard !keyboards.isEmpty else { throw HIDFailure.message("未检测到可配置键盘。") }
        // Validate and snapshot every service before changing any service.
        let plans = try keyboards.map { service in
            let original = lease.property(service, "UserKeyMapping") as? [[String: Any]] ?? []
            return (service, try CapsLockMapping.replacingIdentity(in: original))
        }
        for (service, map) in plans {
            try lease.set(service, key: "UserKeyMapping", value: map, missingDefault: [[String: Any]](), force: false)
        }
    }
}
