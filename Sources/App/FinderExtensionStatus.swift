import Foundation

enum FinderExtensionStatus: Equatable, Sendable {
    case enabled
    case disabled
    case unknown

    static func parse(_ output: String, identifier: String) -> Self {
        var matches: [Self] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  fields[1] == identifier || fields[1].hasPrefix(identifier + "(") else { continue }
            switch fields[0] {
            case "+": matches.append(.enabled)
            case "-": matches.append(.disabled)
            default: matches.append(.unknown)
            }
        }
        // Missing, default, superseded or ambiguous entries do not prove disablement.
        guard matches.count == 1 else { return .unknown }
        return matches[0]
    }

    static func resolve(registry: Self, apiEnabled: Bool) -> Self {
        registry == .unknown && apiEnabled ? .enabled : registry
    }

    static func read(identifier: String, apiEnabled: Bool) async -> Self {
        let registry = await Task.detached(priority: .utility) {
            queryRegistry(identifier: identifier)
        }.value
        return resolve(registry: registry, apiEnabled: apiEnabled)
    }

    private static func queryRegistry(identifier: String) -> Self {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.FinderSync", "-i", identifier]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { return .unknown }

        // Run off the main thread and bound the wait if the registry service stalls.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                return .unknown
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return .unknown
        }
        return parse(text, identifier: identifier)
    }
}
