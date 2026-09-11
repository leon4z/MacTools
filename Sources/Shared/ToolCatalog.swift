import AppKit
import Foundation

struct LaunchTool {
    let id: String
    let name: String
    let bundleIdentifiers: [String]
    let applicationNames: [String]
    let fallbackPaths: [String]
    let opensParentForFiles: Bool

    init(
        id: String? = nil,
        name: String,
        bundleIdentifiers: [String],
        applicationNames: [String],
        fallbackPaths: [String],
        opensParentForFiles: Bool
    ) {
        self.id = id ?? bundleIdentifiers.first ?? fallbackPaths.first ?? name
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.applicationNames = applicationNames
        self.fallbackPaths = fallbackPaths
        self.opensParentForFiles = opensParentForFiles
    }

    var applicationURL: URL? {
        for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }

        for applicationName in applicationNames {
            for basePath in ToolCatalog.applicationSearchPaths {
                let path = "\(basePath)/\(applicationName).app"
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }

        return nil
    }
}

struct ResolvedLaunchTool {
    let tool: LaunchTool
    let applicationURL: URL
}

enum ToolCatalog {
    static let applicationSearchPaths = [
        "/Applications",
        "\(NSHomeDirectory())/Applications",
        "/System/Applications",
        "/System/Applications/Utilities"
    ]

    static let candidates: [LaunchTool] = [
        LaunchTool(name: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"], applicationNames: ["Cursor"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Visual Studio Code", bundleIdentifiers: ["com.microsoft.VSCode"], applicationNames: ["Visual Studio Code"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Windsurf", bundleIdentifiers: ["com.exafunction.windsurf"], applicationNames: ["Windsurf"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Trae", bundleIdentifiers: ["com.trae.app", "com.bytedance.trae"], applicationNames: ["Trae", "Trae CN"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Zed", bundleIdentifiers: ["dev.zed.Zed"], applicationNames: ["Zed"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Xcode", bundleIdentifiers: ["com.apple.dt.Xcode"], applicationNames: ["Xcode"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "IntelliJ IDEA", bundleIdentifiers: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"], applicationNames: ["IntelliJ IDEA", "IntelliJ IDEA CE"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "WebStorm", bundleIdentifiers: ["com.jetbrains.WebStorm"], applicationNames: ["WebStorm"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "PyCharm", bundleIdentifiers: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"], applicationNames: ["PyCharm", "PyCharm CE"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "GoLand", bundleIdentifiers: ["com.jetbrains.goland"], applicationNames: ["GoLand"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Android Studio", bundleIdentifiers: ["com.google.android.studio"], applicationNames: ["Android Studio"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Sublime Text", bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3"], applicationNames: ["Sublime Text"], fallbackPaths: [], opensParentForFiles: false),
        LaunchTool(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"], applicationNames: ["Terminal"], fallbackPaths: ["/System/Applications/Utilities/Terminal.app"], opensParentForFiles: true),
        LaunchTool(name: "iTerm", bundleIdentifiers: ["com.googlecode.iterm2"], applicationNames: ["iTerm", "iTerm2"], fallbackPaths: [], opensParentForFiles: true),
        LaunchTool(name: "Warp", bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp"], applicationNames: ["Warp"], fallbackPaths: [], opensParentForFiles: true),
        LaunchTool(name: "Ghostty", bundleIdentifiers: ["com.mitchellh.ghostty"], applicationNames: ["Ghostty"], fallbackPaths: [], opensParentForFiles: true),
        LaunchTool(name: "Alacritty", bundleIdentifiers: ["org.alacritty"], applicationNames: ["Alacritty"], fallbackPaths: [], opensParentForFiles: true),
        LaunchTool(name: "kitty", bundleIdentifiers: ["net.kovidgoyal.kitty"], applicationNames: ["kitty"], fallbackPaths: [], opensParentForFiles: true)
    ]

    static func configuredTools() -> [ConfiguredTool] {
        switch ToolConfigurationStore.loadResult() {
        case .missing:
            return defaultConfiguredTools()
        case let .loaded(tools):
            return tools
        case .invalid:
            return []
        }
    }

    static func defaultConfiguredTools() -> [ConfiguredTool] {
        candidates.compactMap { candidate in
            guard let applicationURL = candidate.applicationURL else { return nil }
            let actualBundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier ?? candidate.bundleIdentifiers.first
            return ConfiguredTool(
                id: actualBundleIdentifier ?? applicationURL.standardizedFileURL.path,
                name: candidate.name,
                bundleIdentifier: actualBundleIdentifier,
                applicationPath: applicationURL.standardizedFileURL.path,
                isEnabled: true,
                opensParentForFiles: candidate.opensParentForFiles
            )
        }
    }

    static func resolvedAvailableTools() -> [ResolvedLaunchTool] {
        resolvedTools(from: configuredTools())
    }

    static func resolvedAvailableTool(withID id: String) -> ResolvedLaunchTool? {
        resolvedAvailableTools().first { $0.tool.id == id }
    }

    static func resolvedTools(from configuredTools: [ConfiguredTool]) -> [ResolvedLaunchTool] {
        configuredTools.compactMap { configuredTool in
            guard configuredTool.isEnabled else { return nil }
            let tool = launchTool(for: configuredTool)
            guard let applicationURL = tool.applicationURL else { return nil }
            return ResolvedLaunchTool(tool: tool, applicationURL: applicationURL)
        }
    }

    static func launchTool(for configuredTool: ConfiguredTool) -> LaunchTool {
        LaunchTool(
            id: configuredTool.id,
            name: configuredTool.name,
            bundleIdentifiers: configuredTool.bundleIdentifier.map { [$0] } ?? [],
            applicationNames: [],
            fallbackPaths: [configuredTool.applicationPath],
            opensParentForFiles: configuredTool.opensParentForFiles
        )
    }

    static func configuredTool(forApplicationURL applicationURL: URL) -> ConfiguredTool? {
        let standardizedURL = applicationURL.standardizedFileURL
        guard
            standardizedURL.pathExtension.lowercased() == "app",
            FileManager.default.fileExists(atPath: standardizedURL.path)
        else {
            return nil
        }

        let bundle = Bundle(url: standardizedURL)
        let bundleIdentifier = bundle?.bundleIdentifier
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? standardizedURL.deletingPathExtension().lastPathComponent

        return ConfiguredTool(
            id: bundleIdentifier ?? standardizedURL.path,
            name: displayName,
            bundleIdentifier: bundleIdentifier,
            applicationPath: standardizedURL.path,
            isEnabled: true,
            opensParentForFiles: prefersParentForFiles(
                bundleIdentifier: bundleIdentifier,
                applicationName: displayName
            )
        )
    }

    static func prefersParentForFiles(bundleIdentifier: String?, applicationName: String) -> Bool {
        if let bundleIdentifier,
           let candidate = candidates.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) {
            return candidate.opensParentForFiles
        }

        let knownTerminalBundleIdentifiers = Set([
            "com.github.wez.wezterm",
            "com.raphaelamorim.rio",
            "co.zeit.hyper",
            "org.tabby",
            "org.tabby-terminal.Tabby"
        ])
        if let bundleIdentifier, knownTerminalBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let terminalNames = Set([
            "terminal", "iterm", "iterm2", "warp", "ghostty", "alacritty", "kitty",
            "wezterm", "rio", "hyper", "tabby", "wave terminal"
        ])
        return terminalNames.contains(applicationName.lowercased())
    }

    static func targetURL(for selectedURL: URL, tool: LaunchTool) -> URL {
        guard tool.opensParentForFiles else {
            return selectedURL
        }

        let isDirectory = (try? selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? selectedURL : selectedURL.deletingLastPathComponent()
    }
}
