import AppKit
import Foundation

struct ToolMenuEntry {
    let id: String
    let name: String
    let icon: NSImage
}

enum ToolMenuConfigurationStamp: Equatable {
    case missing
    case available(fileNumber: UInt64, fileSize: UInt64, modificationDate: Date)
    case unreadable

    static func current(
        at url: URL = ToolConfigurationStore.configurationURL(),
        fileManager: FileManager = .default
    ) -> ToolMenuConfigurationStamp {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return .unreadable
        }

        return .available(
            fileNumber: fileNumber,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
    }
}

final class ToolMenuCache {
    typealias StampProvider = () -> ToolMenuConfigurationStamp
    typealias ToolProvider = () -> [ResolvedLaunchTool]
    typealias IconProvider = (URL) -> NSImage

    private let maximumAge: TimeInterval
    private let stampProvider: StampProvider
    private let toolProvider: ToolProvider
    private let iconProvider: IconProvider

    private var cachedStamp: ToolMenuConfigurationStamp?
    private var cachedAt: Date?
    private var cachedEntries: [ToolMenuEntry] = []

    init(
        maximumAge: TimeInterval = 30,
        stampProvider: @escaping StampProvider = { ToolMenuConfigurationStamp.current() },
        toolProvider: @escaping ToolProvider = { ToolCatalog.resolvedAvailableTools() },
        iconProvider: @escaping IconProvider = { applicationURL in
            let workspaceIcon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            let icon = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    ) {
        self.maximumAge = maximumAge
        self.stampProvider = stampProvider
        self.toolProvider = toolProvider
        self.iconProvider = iconProvider
    }

    func entries(now: Date = Date()) -> [ToolMenuEntry] {
        let currentStamp = stampProvider()
        if
            currentStamp == cachedStamp,
            let cachedAt,
            now >= cachedAt,
            now.timeIntervalSince(cachedAt) < maximumAge
        {
            return cachedEntries
        }

        cachedEntries = toolProvider().map { resolvedTool in
            ToolMenuEntry(
                id: resolvedTool.tool.id,
                name: resolvedTool.tool.name,
                icon: iconProvider(resolvedTool.applicationURL)
            )
        }
        cachedStamp = currentStamp
        cachedAt = now
        return cachedEntries
    }
}
