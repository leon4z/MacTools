import Foundation

/// Device-agnostic recovery transaction; testable without touching any HID state.
final class PropertyLeaseJournal {
    private let url: URL
    private let bootID: String
    private let available: () -> Set<String>
    private let read: (String, String) -> Any?
    private let write: (String, String, Any) -> Bool
    private var records: [[String: Any]] = []
    private var loadFailed = false
    init(url: URL, bootID: String, available: @escaping () -> Set<String>,
         read: @escaping (String, String) -> Any?, write: @escaping (String, String, Any) -> Bool) {
        self.url = url; self.bootID = bootID; self.available = available; self.read = read; self.write = write
    }
    static func equal(_ a: Any, _ b: Any) -> Bool { (a as? NSObject)?.isEqual(b) ?? false }
    func recover() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { loadFailed = false; return }
        do {
            guard let container = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
                  let oldBoot = container["boot"] as? String, let loaded = container["records"] as? [[String: Any]],
                  loaded.allSatisfy({ $0["id"] is String && $0["key"] is String && $0["original"] != nil && $0["written"] != nil }) else {
                throw NSError(domain: "MacTools.Recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "设备恢复记录无法读取，已暂停参数修改。"])
            }
            // HID service IDs belong to one boot. Never restore stale IDs into a
            // different boot where the same number could identify another device.
            records = oldBoot == bootID ? loaded : []
            loadFailed = false
        } catch { loadFailed = true; throw error }
        try restore()
    }
    func set(id: String, key: String, value: Any, missingDefault: Any, force: Bool = false) throws {
        guard !loadFailed else { throw failure("恢复记录尚未成功读取。") }
        let current = read(id, key) ?? missingDefault
        if !force && Self.equal(current, value) { return }
        records.append(["id": id, "key": key, "original": current, "written": value])
        try persist() // durable before touching the device
        guard write(id, key, value), let result = read(id, key), Self.equal(result, value) else {
            throw failure("设备未确认参数更新。")
        }
    }
    func restore() throws {
        guard !loadFailed else { throw failure("恢复记录读取失败，原记录已保留。") }
        let online = available()
        var retained: [[String: Any]] = []
        var failed = false
        var blockedRefresh = Set<String>()
        // Restore geometry/linear mode before acceleration; writing acceleration
        // last makes the OS rebuild its curve using the restored parameters.
        let ordered = records.reversed().sorted { a, b in priority(a) < priority(b) }
        for entry in ordered {
            let id = entry["id"] as! String, key = entry["key"] as! String
            let original = entry["original"]!, written = entry["written"]!
            if priority(entry) == 1 && blockedRefresh.contains(id) { retained.append(entry); continue }
            guard online.contains(id) else { retained.append(entry); blockedRefresh.insert(id); continue }
            guard let current = read(id, key) else { retained.append(entry); blockedRefresh.insert(id); failed = true; continue }
            let restoreValue: Any
            if key == "UserKeyMapping", let before = original as? [[String: Any]],
               let ours = written as? [[String: Any]], let now = current as? [[String: Any]] {
                let additions = ours.filter { item in !before.contains(where: { Self.equal($0, item) }) }
                if Self.equal(now, ours) {
                    restoreValue = before
                } else {
                    // Remove our pairs and restore identities temporarily replaced
                    // by us, while respecting newer mappings of the same source.
                    var merged = now.filter { item in !additions.contains(where: { Self.equal($0, item) }) }
                    let removals = before.filter { item in !ours.contains(where: { Self.equal($0, item) }) }
                    for item in removals {
                        guard let source = item["HIDKeyboardModifierMappingSrc"] else { continue }
                        if !merged.contains(where: { Self.equal($0["HIDKeyboardModifierMappingSrc"] ?? NSNull(), source) }) {
                            merged.append(item)
                        }
                    }
                    restoreValue = merged
                }
                if Self.equal(restoreValue, now) { continue }
            } else {
                guard Self.equal(current, written) else { continue } // external owner wins
                restoreValue = original
            }
            if !write(id, key, restoreValue) || !Self.equal(read(id, key) ?? NSNull(), restoreValue) {
                retained.append(entry); blockedRefresh.insert(id); failed = true
            }
        }
        records = retained
        try persist()
        if failed { throw failure("部分设备参数尚未恢复，请重新检查。") }
    }
    var ownershipIntact: Bool {
        let online = available()
        return records.allSatisfy { e in
            let id = e["id"] as! String, key = e["key"] as! String
            if !online.contains(id) { return true }
            if key == "UserKeyMapping", let before = e["original"] as? [[String: Any]],
               let ours = e["written"] as? [[String: Any]], let now = read(id, key) as? [[String: Any]] {
                let additions = ours.filter { item in !before.contains(where: { Self.equal($0, item) }) }
                return additions.allSatisfy { item in now.contains(where: { Self.equal($0, item) }) }
            }
            return Self.equal(read(id, key) ?? NSNull(), e["written"]!)
        }
    }
    var pendingCount: Int { records.count }
    private func priority(_ entry: [String: Any]) -> Int {
        let key = entry["key"] as? String ?? ""
        return ["HIDMouseAcceleration", "HIDPointerAcceleration"].contains(key) ? 1 : 0
    }
    private func persist() throws {
        guard !loadFailed else { throw failure("不能覆盖尚未读取的恢复记录。") }
        if records.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["boot": bootID, "records": records], format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
        }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "MacTools.Recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
