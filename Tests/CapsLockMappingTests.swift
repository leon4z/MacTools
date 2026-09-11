import Foundation

@main enum CapsLockMappingTests {
    static func pair(_ src: UInt64, _ dst: UInt64) -> [String: Any] {
        ["HIDKeyboardModifierMappingSrc": NSNumber(value: src), "HIDKeyboardModifierMappingDst": NSNumber(value: dst)]
    }
    static func main() throws {
        let caps = CapsLockMapping.source, f18 = CapsLockMapping.destination
        let other: UInt64 = 0x700000004
        let ours = pair(caps, f18), unrelated = pair(other, other + 1)
        let old = [unrelated, pair(caps, caps), pair(f18, f18)]
        let planned = try CapsLockMapping.replacingIdentity(in: old)
        precondition(PropertyLeaseJournal.equal(planned, [unrelated, ours]))
        let emptyPlan = try CapsLockMapping.replacingIdentity(in: [])
        precondition(PropertyLeaseJournal.equal(emptyPlan, [ours]))
        for conflicting in [pair(caps, other), pair(f18, other), pair(other, f18), ours] {
            var rejected = false
            do { _ = try CapsLockMapping.replacingIdentity(in: [conflicting]) } catch { rejected = true }
            precondition(rejected, "genuine source or F18 destination conflicts must remain blocked")
        }
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("local/test-build/caps-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var current = old
        let url = dir.appendingPathComponent("journal.plist")
        func journal() -> PropertyLeaseJournal {
            PropertyLeaseJournal(url: url, bootID: "test", available: { ["keyboard"] }, read: { _, _ in current }, write: { _, _, value in current = value as! [[String: Any]]; return true })
        }
        let lease = journal()
        try lease.set(id: "keyboard", key: "UserKeyMapping", value: planned, missingDefault: [[String: Any]]())
        precondition(lease.ownershipIntact)
        try lease.restore()
        precondition(PropertyLeaseJournal.equal(current, old), "disable restores identities and original ordering")
        try lease.set(id: "keyboard", key: "UserKeyMapping", value: planned, missingDefault: [[String: Any]]())
        try journal().recover()
        precondition(PropertyLeaseJournal.equal(current, old), "restart recovery restores original identities")
        let external = pair(other + 2, other + 3)
        let newLease = journal()
        try newLease.set(id: "keyboard", key: "UserKeyMapping", value: planned, missingDefault: [[String: Any]]())
        current.append(external)
        try newLease.restore()
        precondition(current.contains { PropertyLeaseJournal.equal($0, external) })
        precondition(current.contains { PropertyLeaseJournal.equal($0, pair(caps, caps)) })
        precondition(!current.contains { PropertyLeaseJournal.equal($0, ours) })
        current = old
        try newLease.set(id: "keyboard", key: "UserKeyMapping", value: planned, missingDefault: [[String: Any]]())
        let externalCaps = pair(caps, other)
        current.append(externalCaps)
        try newLease.restore()
        precondition(current.contains { PropertyLeaseJournal.equal($0, externalCaps) })
        precondition(!current.contains { PropertyLeaseJournal.equal($0, pair(caps, caps)) }, "later source owner wins")
        print("CapsLockMappingTests: identity replacement, 4 conflicts, disable/restart recovery and external ownership passed")
    }
}
