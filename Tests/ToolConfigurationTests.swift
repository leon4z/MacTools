import AppKit
import Foundation

@main
enum ToolConfigurationTests {
    static func main() throws {
        try testConfigurationRoundTrip()
        try testEmptyConfigurationRoundTrip()
        try testInvalidConfigurationFailsClosed()
        try testDuplicateIdentifiersAreRejected()
        try testConfigurationLocations()
        try testMoveRequestStaysWithinSharedGrant()
        try testOpenRequestRoundTrip()
        try testOpenRequestIsConsumedOnce()
        try testExpiredOpenRequestIsRejected()
        try testInvalidOpenRequestIDIsRejected()
        try testArbitraryAppPathRequestIsRejected()
        try testSmartTargetSelection()
        try testTerminalClassification()
        try testSelectedApplicationPathIsPreferred()
        print("ToolConfigurationTests: all tests passed")
    }

    private static func testConfigurationRoundTrip() throws {
        try withTemporaryDirectory("round-trip") { directory in
            let configurationURL = directory.appendingPathComponent("ToolConfiguration.json")
            let tools = [sampleTool(id: "com.example.Editor")]
            try ToolConfigurationStore.save(tools, to: configurationURL)
            try expect(ToolConfigurationStore.loadResult(from: configurationURL) == .loaded(tools), "configuration round trip")
        }
    }

    private static func testEmptyConfigurationRoundTrip() throws {
        try withTemporaryDirectory("empty") { directory in
            let configurationURL = directory.appendingPathComponent("ToolConfiguration.json")
            try ToolConfigurationStore.save([], to: configurationURL)
            try expect(ToolConfigurationStore.loadResult(from: configurationURL) == .loaded([]), "empty configuration stays empty")
        }
    }

    private static func testInvalidConfigurationFailsClosed() throws {
        try withTemporaryDirectory("invalid") { directory in
            let configurationURL = directory.appendingPathComponent("ToolConfiguration.json")
            try Data("{\"version\":999,\"tools\":[]}".utf8).write(to: configurationURL)
            try expect(ToolConfigurationStore.loadResult(from: configurationURL) == .invalid, "unsupported configuration version is invalid")
        }
    }

    private static func testDuplicateIdentifiersAreRejected() throws {
        try withTemporaryDirectory("duplicates") { directory in
            let configurationURL = directory.appendingPathComponent("ToolConfiguration.json")
            do {
                try ToolConfigurationStore.save(
                    [sampleTool(id: "duplicate"), sampleTool(id: "duplicate")],
                    to: configurationURL
                )
                throw TestFailure(message: "duplicate identifiers should be rejected")
            } catch let error as TestFailure {
                throw error
            } catch {
                try expect(!FileManager.default.fileExists(atPath: configurationURL.path), "invalid configuration is not written")
            }
        }
    }

    private static func testConfigurationLocations() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let extensionURL = ToolConfigurationStore.configurationURL(isExtensionProcess: true, homeDirectory: home)
        let hostURL = ToolConfigurationStore.configurationURL(isExtensionProcess: false, homeDirectory: home)
        try expect(
            extensionURL.path == "/Users/example/Library/Application Support/MacTools/ToolConfiguration.json",
            "extension configuration path"
        )
        try expect(
            hostURL.path == "/Users/example/Library/Containers/com.leon4z.MacTools.FinderExtension/Data/Library/Application Support/MacTools/ToolConfiguration.json",
            "host configuration path"
        )
        let requestDirectory = OpenToolRequestStore.requestDirectoryURL(isExtensionProcess: false, homeDirectory: home)
        try expect(
            requestDirectory.path == "/Users/example/Library/Containers/com.leon4z.MacTools.FinderExtension/Data/Library/Application Support/MacTools/OpenToolRequests",
            "host open request path"
        )
    }

    private static func testMoveRequestStaysWithinSharedGrant() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let containerHome = home.appendingPathComponent(
            "Library/Containers/com.leon4z.MacTools.FinderExtension/Data", isDirectory: true
        )
        let hostDirectory = MoveRequestStore.requestDirectoryURL(isExtensionProcess: false, homeDirectory: home)
        let extensionDirectory = MoveRequestStore.requestDirectoryURL(isExtensionProcess: true, homeDirectory: containerHome)
        let grantedDirectory = ToolConfigurationStore.sharedApplicationSupportURL(isExtensionProcess: false, homeDirectory: home)
        try expect(hostDirectory == extensionDirectory, "host and sandboxed extension address the same move requests")
        try expect(hostDirectory.deletingLastPathComponent() == grantedDirectory, "move requests stay inside the host's directory grant")
    }

    private static func testOpenRequestRoundTrip() throws {
        let request = OpenToolRequest(requestID: UUID().uuidString)
        guard let callbackURL = request.callbackURL, let decoded = OpenToolRequest(url: callbackURL) else {
            throw TestFailure(message: "open request should encode and decode")
        }
        try expect(decoded == request, "open request round trip")
        try expect(!callbackURL.absoluteString.contains("selectedPath"), "callback URL does not expose the selected path")
        try expect(!callbackURL.absoluteString.contains("toolID"), "callback URL does not expose the tool ID")
    }

    private static func testOpenRequestIsConsumedOnce() throws {
        try withTemporaryDirectory("request-consume") { directory in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let payload = OpenToolRequestPayload(
                requestID: UUID().uuidString,
                createdAt: now,
                toolID: "com.example.Editor/测试",
                selectedPath: "/tmp/带 空格/hello & goodbye.txt"
            )
            try OpenToolRequestStore.write(payload, to: directory)
            try expect(
                OpenToolRequestStore.consume(requestID: payload.requestID, from: directory, now: now) == payload,
                "valid request payload is consumed"
            )
            try expect(
                OpenToolRequestStore.consume(requestID: payload.requestID, from: directory, now: now) == nil,
                "request payload cannot be replayed"
            )
        }
    }

    private static func testExpiredOpenRequestIsRejected() throws {
        try withTemporaryDirectory("request-expired") { directory in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let payload = OpenToolRequestPayload(
                requestID: UUID().uuidString,
                createdAt: now.addingTimeInterval(-61),
                toolID: "com.example.Editor",
                selectedPath: "/tmp/file.txt"
            )
            try OpenToolRequestStore.write(payload, to: directory)
            try expect(
                OpenToolRequestStore.consume(requestID: payload.requestID, from: directory, now: now) == nil,
                "expired request payload is rejected"
            )
        }
    }

    private static func testInvalidOpenRequestIDIsRejected() throws {
        try withTemporaryDirectory("request-invalid-id") { directory in
            try expect(
                OpenToolRequestStore.consume(requestID: "../ToolConfiguration", from: directory, now: Date()) == nil,
                "request ID cannot traverse the shared directory"
            )
        }
    }

    private static func testArbitraryAppPathRequestIsRejected() throws {
        let untrustedURL = URL(string: "mactools://open?targetPath=/tmp/a&appPath=/Applications/Test.app")!
        try expect(OpenToolRequest(url: untrustedURL) == nil, "arbitrary app path request is rejected")
    }

    private static func testSmartTargetSelection() throws {
        try withTemporaryDirectory("smart-target") { directory in
            let file = directory.appendingPathComponent("file.txt")
            try Data().write(to: file)

            let terminal = LaunchTool(
                id: "terminal",
                name: "Terminal",
                bundleIdentifiers: [],
                applicationNames: [],
                fallbackPaths: [],
                opensParentForFiles: true
            )
            let editor = LaunchTool(
                id: "editor",
                name: "Editor",
                bundleIdentifiers: [],
                applicationNames: [],
                fallbackPaths: [],
                opensParentForFiles: false
            )

            try expect(ToolCatalog.targetURL(for: file, tool: terminal) == directory, "terminal opens parent for a file")
            try expect(ToolCatalog.targetURL(for: directory, tool: terminal) == directory, "terminal opens selected directory")
            try expect(ToolCatalog.targetURL(for: file, tool: editor) == file, "editor opens selected file")
        }
    }

    private static func testTerminalClassification() throws {
        try expect(
            ToolCatalog.prefersParentForFiles(bundleIdentifier: "com.apple.Terminal", applicationName: "Anything"),
            "known terminal bundle is classified"
        )
        try expect(
            ToolCatalog.prefersParentForFiles(bundleIdentifier: nil, applicationName: "Ghostty"),
            "terminal name fallback is classified"
        )
        try expect(
            ToolCatalog.prefersParentForFiles(bundleIdentifier: "com.github.wez.wezterm", applicationName: "Anything"),
            "configured WezTerm bundle is classified"
        )
        try expect(
            ToolCatalog.prefersParentForFiles(bundleIdentifier: nil, applicationName: "Rio"),
            "configured terminal name is classified"
        )
        try expect(
            !ToolCatalog.prefersParentForFiles(bundleIdentifier: nil, applicationName: "Obsidian"),
            "ordinary app opens the selected item"
        )
    }

    private static func testSelectedApplicationPathIsPreferred() throws {
        try withTemporaryDirectory("app-priority") { directory in
            let appURL = directory.appendingPathComponent("Example.app", isDirectory: true)
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            let tool = LaunchTool(
                id: "example",
                name: "Example",
                bundleIdentifiers: ["com.apple.Terminal"],
                applicationNames: [],
                fallbackPaths: [appURL.path],
                opensParentForFiles: false
            )
            try expect(tool.applicationURL?.standardizedFileURL == appURL.standardizedFileURL, "saved application path wins over Launch Services")
        }
    }

    private static func sampleTool(id: String) -> ConfiguredTool {
        ConfiguredTool(
            id: id,
            name: "Example",
            bundleIdentifier: id,
            applicationPath: "/Applications/Example.app",
            isEnabled: true,
            opensParentForFiles: false
        )
    }

    private static func withTemporaryDirectory(
        _ label: String,
        body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTools-ToolTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
