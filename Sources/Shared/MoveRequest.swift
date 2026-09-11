import Foundation

struct MoveRequestPayload: Codable {
    let requestID: String
    let createdAt: Date
    let sourcePaths: [String]
}

enum MoveRequestStore {
    private static let directoryName = "FinderRightClick/PendingMove"
    private static let extensionBundleIdentifier = "local.leon.FinderRightClick.Extension"

    static func writeFromExtension(_ payload: MoveRequestPayload) throws {
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = cachesDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: requestURL(payload.requestID, in: directory), options: .atomic)
    }

    static func consumeFromHost(requestID: String) -> MoveRequestPayload? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        return consume(requestURL(requestID, in: hostRequestDirectory()))
    }

    static func consumeOldestFreshRequestFromHost(maximumAge: TimeInterval = 120) -> MoveRequestPayload? {
        let directory = hostRequestDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let now = Date()
        let candidates = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Date)? in
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return modified.map { (url, $0) }
            }
            .sorted { $0.1 < $1.1 }

        for (url, modifiedAt) in candidates {
            guard now.timeIntervalSince(modifiedAt) <= maximumAge else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let payload = consume(url),
               now.timeIntervalSince(payload.createdAt) <= maximumAge,
               payload.createdAt.timeIntervalSince(now) <= 30 {
                return payload
            }
        }

        return nil
    }

    private static func consume(_ url: URL) -> MoveRequestPayload? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(MoveRequestPayload.self, from: data),
            requestURL(payload.requestID, in: url.deletingLastPathComponent()).standardizedFileURL ==
                url.standardizedFileURL,
            !payload.sourcePaths.isEmpty,
            payload.sourcePaths.allSatisfy({ $0.hasPrefix("/") })
        else {
            return nil
        }
        return payload
    }

    private static func hostRequestDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(extensionBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Caches", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func requestURL(_ requestID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(requestID).appendingPathExtension("json")
    }
}
