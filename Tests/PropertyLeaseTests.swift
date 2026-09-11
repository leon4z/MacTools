import Foundation

@main enum PropertyLeaseTests {
    static var count = 0
    static func check(_ value: Bool, _ description: String) throws {
        count += 1
        if !value { throw NSError(domain: "PropertyLeaseTests", code: count, userInfo: [NSLocalizedDescriptionKey: description]) }
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsLeaseTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recovery.plist")
        var values: [String: Any] = ["speed": 100, "HIDMouseAcceleration": 10, "HIDPointerResolution": 400]
        var online = true
        var writes: [String] = []
        var failResolution = false
        let journal = PropertyLeaseJournal(url: url, bootID: "boot-a", available: { online ? ["mouse"] : [] }, read: { _, key in values[key] }, write: { _, key, value in writes.append(key); if failResolution && key == "HIDPointerResolution" { return false }; values[key] = value; return true })
        try journal.set(id: "mouse", key: "speed", value: 200, missingDefault: 100)
        try check(values["speed"] as? Int == 200 && FileManager.default.fileExists(atPath: url.path), "write is journaled")
        try journal.restore()
        try check(values["speed"] as? Int == 100 && !FileManager.default.fileExists(atPath: url.path), "normal disable restores")
        try journal.set(id: "mouse", key: "speed", value: 200, missingDefault: 100)
        values["speed"] = 300
        try journal.restore()
        try check(values["speed"] as? Int == 300, "external tool wins compare-and-swap")
        try journal.set(id: "mouse", key: "speed", value: 400, missingDefault: 100)
        online = false; try journal.restore()
        try check(journal.pendingCount == 1 && FileManager.default.fileExists(atPath: url.path), "offline device retains recovery record")
        online = true; try journal.restore()
        try check(values["speed"] as? Int == 300 && journal.pendingCount == 0, "reconnected device recovers")
        try journal.set(id: "mouse", key: "HIDPointerResolution", value: 200, missingDefault: 400)
        try journal.set(id: "mouse", key: "HIDMouseAcceleration", value: 20, missingDefault: 10, force: true)
        writes = []; try journal.restore()
        try check(writes == ["HIDPointerResolution", "HIDMouseAcceleration"], "acceleration refresh follows geometry restoration")
        try journal.set(id: "mouse", key: "HIDPointerResolution", value: 200, missingDefault: 400)
        try journal.set(id: "mouse", key: "HIDMouseAcceleration", value: 20, missingDefault: 10, force: true)
        failResolution = true; writes = []
        do { try journal.restore() } catch {}
        try check(journal.pendingCount == 2 && writes == ["HIDPointerResolution"], "failed geometry retains acceleration refresh")
        failResolution = false; writes = []; try journal.restore()
        try check(journal.pendingCount == 0 && writes == ["HIDPointerResolution", "HIDMouseAcceleration"], "retry restores geometry then refreshes acceleration")
        try journal.set(id: "mouse", key: "speed", value: 500, missingDefault: 100)
        let restarted = PropertyLeaseJournal(url: url, bootID: "boot-a", available: { ["mouse"] }, read: { _,key in values[key] }, write: { _, key,value in values[key] = value; return true })
        try restarted.recover()
        try check(values["speed"] as? Int == 300, "crash recovery restores on same boot")
        try journal.set(id: "mouse", key: "speed", value: 600, missingDefault: 100)
        let rebooted = PropertyLeaseJournal(url: url, bootID: "boot-b", available: { ["mouse"] }, read: { _,key in values[key] }, write: { _,key,value in values[key] = value; return true })
        try rebooted.recover()
        try check(values["speed"] as? Int == 600, "old boot IDs cannot target new devices")
        // Finish the old in-memory test lease before the independent mapping scenario.
        try journal.restore()
        let ours: [String: Any] = ["HIDKeyboardModifierMappingSrc": 57, "HIDKeyboardModifierMappingDst": 109]
        let unrelated: [String: Any] = ["HIDKeyboardModifierMappingSrc": 4, "HIDKeyboardModifierMappingDst": 5]
        values["UserKeyMapping"] = [[String: Any]]()
        try journal.set(id: "mouse", key: "UserKeyMapping", value: [ours], missingDefault: [[String: Any]]())
        values["UserKeyMapping"] = [ours, unrelated]
        try check(journal.ownershipIntact, "unrelated external keyboard mapping does not break lease")
        try journal.restore()
        try check(PropertyLeaseJournal.equal(values["UserKeyMapping"]!, [unrelated]), "restore removes only our added mapping")
        let corrupt = Data("corrupt recovery".utf8); try corrupt.write(to: url)
        let bad = PropertyLeaseJournal(url: url, bootID: "boot-a", available: { [] }, read: { _,_ in nil }, write: { _,_,_ in true })
        var failed = false
        do { try bad.recover() } catch { failed = true }
        try check(failed, "corrupt journal reports failure")
        do { try bad.restore() } catch {}
        try check(try Data(contentsOf: url) == corrupt, "stop after load failure preserves exact corrupt record")
        failed = false
        do { try bad.set(id: "mouse", key: "speed", value: 700, missingDefault: 100) } catch { failed = true }
        try check(failed && (try Data(contentsOf: url)) == corrupt, "load failure blocks new writes")
        print("PropertyLeaseTests: \(count) checks passed")
    }
}
