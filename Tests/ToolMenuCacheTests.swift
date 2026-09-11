import AppKit
import Foundation

@main
enum ToolMenuCacheTests {
    static func main() throws {
        try testCacheReusesResolvedToolsAndIcons()
        try testConfigurationChangeInvalidatesCache()
        try testExpiredCacheRevalidatesApplications()
        try testConfigurationStampChangesAfterAtomicSave()
        print("ToolMenuCacheTests: all tests passed")
    }

    private static func testCacheReusesResolvedToolsAndIcons() throws {
        let counters = Counters()
        let cache = makeCache(
            maximumAge: 30,
            stampProvider: { .missing },
            counters: counters
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = cache.entries(now: now)
        let second = cache.entries(now: now.addingTimeInterval(10))

        try expect(first.map(\.id) == ["example"], "first load returns the configured tool")
        try expect(second.map(\.id) == ["example"], "cached load returns the configured tool")
        try expect(counters.loadCount == 1, "unchanged configuration reuses resolved tools")
        try expect(counters.iconCount == 1, "unchanged configuration reuses icons")
    }

    private static func testConfigurationChangeInvalidatesCache() throws {
        var stamp = ToolMenuConfigurationStamp.missing
        let counters = Counters()
        let cache = makeCache(
            maximumAge: 30,
            stampProvider: { stamp },
            counters: counters
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = cache.entries(now: now)
        stamp = .available(fileNumber: 2, fileSize: 10, modificationDate: now)
        _ = cache.entries(now: now.addingTimeInterval(1))

        try expect(counters.loadCount == 2, "configuration change reloads resolved tools immediately")
        try expect(counters.iconCount == 2, "configuration change reloads icons immediately")
    }

    private static func testExpiredCacheRevalidatesApplications() throws {
        let counters = Counters()
        let cache = makeCache(
            maximumAge: 30,
            stampProvider: { .missing },
            counters: counters
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = cache.entries(now: now)
        _ = cache.entries(now: now.addingTimeInterval(30))

        try expect(counters.loadCount == 2, "expired cache revalidates installed applications")
        try expect(counters.iconCount == 2, "expired cache refreshes icons")
    }

    private static func testConfigurationStampChangesAfterAtomicSave() throws {
        try withTemporaryDirectory("stamp") { directory in
            let configurationURL = directory.appendingPathComponent("ToolConfiguration.json")
            let missingStamp = ToolMenuConfigurationStamp.current(at: configurationURL)
            try ToolConfigurationStore.save([sampleConfiguredTool(name: "One")], to: configurationURL)
            let firstStamp = ToolMenuConfigurationStamp.current(at: configurationURL)
            try ToolConfigurationStore.save([sampleConfiguredTool(name: "Two")], to: configurationURL)
            let secondStamp = ToolMenuConfigurationStamp.current(at: configurationURL)

            try expect(missingStamp == .missing, "missing configuration has a stable stamp")
            try expect(firstStamp != .missing, "saved configuration has an available stamp")
            try expect(secondStamp != firstStamp, "atomic configuration replacement changes its stamp")
        }
    }

    private static func makeCache(
        maximumAge: TimeInterval,
        stampProvider: @escaping () -> ToolMenuConfigurationStamp,
        counters: Counters
    ) -> ToolMenuCache {
        let applicationURL = URL(fileURLWithPath: "/Applications/Example.app", isDirectory: true)
        let tool = LaunchTool(
            id: "example",
            name: "Example",
            bundleIdentifiers: [],
            applicationNames: [],
            fallbackPaths: [applicationURL.path],
            opensParentForFiles: false
        )

        return ToolMenuCache(
            maximumAge: maximumAge,
            stampProvider: stampProvider,
            toolProvider: {
                counters.loadCount += 1
                return [ResolvedLaunchTool(tool: tool, applicationURL: applicationURL)]
            },
            iconProvider: { _ in
                counters.iconCount += 1
                return NSImage(size: NSSize(width: 16, height: 16))
            }
        )
    }

    private static func sampleConfiguredTool(name: String) -> ConfiguredTool {
        ConfiguredTool(
            id: "example",
            name: name,
            bundleIdentifier: "com.example.Editor",
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
            .appendingPathComponent("MacTools-ToolMenuCacheTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    private final class Counters {
        var loadCount = 0
        var iconCount = 0
    }

    private struct TestFailure: Error {
        let message: String
    }
}
