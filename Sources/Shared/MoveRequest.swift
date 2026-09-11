import Foundation

struct MoveRequestPayload: Codable {
    let requestID: String
    let createdAt: Date
    let sourcePaths: [String]
}

enum MoveRequestStore {
    private static let directoryName = "PendingMove"

    static func writeFromExtension(_ payload: MoveRequestPayload) throws {
        let directory = requestDirectoryURL(isExtensionProcess: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: requestURL(payload.requestID, in: directory), options: .atomic)
    }

    static func consumeFromHost(requestID: String) -> MoveRequestPayload? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        return consume(requestURL(requestID, in: requestDirectoryURL(isExtensionProcess: false)))
    }

    static func consumeOldestFreshRequestFromHost(maximumAge: TimeInterval = 120) -> MoveRequestPayload? {
        let directory = requestDirectoryURL(isExtensionProcess: false)
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

    static func requestDirectoryURL(
        isExtensionProcess: Bool,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        // Keep requests inside the directory covered by the host's scoped bookmark.
        ToolConfigurationStore.sharedApplicationSupportURL(
            isExtensionProcess: isExtensionProcess,
            homeDirectory: homeDirectory
        ).appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func requestURL(_ requestID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(requestID).appendingPathExtension("json")
    }
}
