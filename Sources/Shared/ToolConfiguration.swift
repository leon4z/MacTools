import Foundation

struct ConfiguredTool: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var bundleIdentifier: String?
    var applicationPath: String
    var isEnabled: Bool
    var opensParentForFiles: Bool
}

enum ToolConfigurationLoadResult: Equatable {
    case missing
    case loaded([ConfiguredTool])
    case invalid
}

enum ToolConfigurationStore {
    private struct StoredConfiguration: Codable {
        let version: Int
        let tools: [ConfiguredTool]
    }

    private static let currentVersion = 1
    static let extensionBundleIdentifier = "local.leon.FinderRightClick.Extension"
    private static let directoryName = "FinderRightClick"
    private static let fileName = "ToolConfiguration.json"

    static func loadResult(from url: URL = configurationURL()) -> ToolConfigurationLoadResult {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
        catch { return .invalid }

        guard
            let stored = try? JSONDecoder().decode(StoredConfiguration.self, from: data),
            stored.version == currentVersion,
            isValid(stored.tools)
        else {
            return .invalid
        }

        return .loaded(stored.tools)
    }

    static func save(_ tools: [ConfiguredTool], to url: URL = configurationURL()) throws {
        guard isValid(tools) else {
            throw NSError(
                domain: "FinderRightClick.ToolConfiguration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "工具配置包含无效或重复的 App"]
            )
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stored = StoredConfiguration(version: currentVersion, tools: tools)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: url, options: .atomic)
    }

    static func configurationURL(
        isExtensionProcess: Bool = Bundle.main.bundleIdentifier == extensionBundleIdentifier,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        sharedApplicationSupportURL(
            isExtensionProcess: isExtensionProcess,
            homeDirectory: homeDirectory
        )
        .appendingPathComponent(fileName, isDirectory: false)
    }

    static func sharedApplicationSupportURL(
        isExtensionProcess: Bool = Bundle.main.bundleIdentifier == extensionBundleIdentifier,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        let baseURL: URL
        if isExtensionProcess {
            baseURL = homeDirectory
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        } else {
            baseURL = homeDirectory
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .appendingPathComponent(extensionBundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
        }

        return baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func isValid(_ tools: [ConfiguredTool]) -> Bool {
        guard tools.count <= 512 else { return false }
        var ids = Set<String>()
        for tool in tools {
            guard
                !tool.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                tool.applicationPath.hasPrefix("/"),
                URL(fileURLWithPath: tool.applicationPath).pathExtension.lowercased() == "app",
                ids.insert(tool.id).inserted
            else {
                return false
            }
        }
        return true
    }
}

struct OpenToolRequestPayload: Codable, Equatable {
    let requestID: String
    let createdAt: Date
    let toolID: String
    let selectedPath: String
}

struct OpenToolRequest: Equatable {
    let requestID: String

    init(requestID: String) {
        self.requestID = requestID
    }

    init?(url: URL) {
        guard url.scheme == "finderrightclick", url.host == "open" else { return nil }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard
            let requestID = queryItems.first(where: { $0.name == "requestID" })?.value,
            UUID(uuidString: requestID)?.uuidString == requestID
        else {
            return nil
        }

        self.requestID = requestID
    }

    var callbackURL: URL? {
        var components = URLComponents()
        components.scheme = "finderrightclick"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "requestID", value: requestID)
        ]
        return components.url
    }
}

enum OpenToolRequestStore {
    private static let requestDirectoryName = "OpenToolRequests"
    private static let maximumAge: TimeInterval = 60

    static func writeFromExtension(_ payload: OpenToolRequestPayload) throws {
        try write(
            payload,
            to: requestDirectoryURL(isExtensionProcess: true)
        )
    }

    static func consumeFromHost(requestID: String) -> OpenToolRequestPayload? {
        consume(
            requestID: requestID,
            from: requestDirectoryURL(isExtensionProcess: false),
            now: Date()
        )
    }

    static func discardFromExtension(requestID: String) {
        guard let canonicalID = canonicalRequestID(requestID) else { return }
        let url = requestURL(
            requestID: canonicalID,
            directoryURL: requestDirectoryURL(isExtensionProcess: true)
        )
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ payload: OpenToolRequestPayload, to directoryURL: URL) throws {
        guard
            canonicalRequestID(payload.requestID) != nil,
            !payload.toolID.isEmpty,
            payload.selectedPath.hasPrefix("/")
        else {
            throw NSError(
                domain: "FinderRightClick.OpenToolRequest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "打开工具请求无效"]
            )
        }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        removeStaleRequests(from: directoryURL, now: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(
            to: requestURL(requestID: payload.requestID, directoryURL: directoryURL),
            options: .atomic
        )
    }

    static func consume(requestID: String, from directoryURL: URL, now: Date) -> OpenToolRequestPayload? {
        guard let canonicalID = canonicalRequestID(requestID) else { return nil }
        let url = requestURL(requestID: canonicalID, directoryURL: directoryURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? decoder.decode(OpenToolRequestPayload.self, from: data),
            payload.requestID == canonicalID,
            !payload.toolID.isEmpty,
            payload.selectedPath.hasPrefix("/"),
            now.timeIntervalSince(payload.createdAt) >= -5,
            now.timeIntervalSince(payload.createdAt) <= maximumAge
        else {
            return nil
        }

        return payload
    }

    static func requestDirectoryURL(
        isExtensionProcess: Bool,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        ToolConfigurationStore.sharedApplicationSupportURL(
            isExtensionProcess: isExtensionProcess,
            homeDirectory: homeDirectory
        )
        .appendingPathComponent(requestDirectoryName, isDirectory: true)
    }

    private static func canonicalRequestID(_ requestID: String) -> String? {
        guard let uuid = UUID(uuidString: requestID), uuid.uuidString == requestID else { return nil }
        return uuid.uuidString
    }

    private static func requestURL(requestID: String, directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(requestID).json", isDirectory: false)
    }

    private static func removeStaleRequests(from directoryURL: URL, now: Date) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.pathExtension == "json" {
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modifiedAt, now.timeIntervalSince(modifiedAt) > maximumAge * 2 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
