import Foundation

struct MousePreferences: Codable, Equatable {
    var scrolling = true
    var smooth = true
    var scrollSpeed = 1.0
    var scrollAcceleration = 0.0
    var smoothing = 0.16
    var reverseVertical = false
    var reverseHorizontal = false
    var pointer = false
    var pointerSpeed = 1.0
    var pointerAcceleration = 0.5
}

enum ModifierTrigger: String, Codable, CaseIterable, Identifiable {
    case capsLock, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand, leftShift, rightShift
    var id: Self { self }
    var title: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .leftControl: return "左 Control"
        case .rightControl: return "右 Control"
        case .leftOption: return "左 Option"
        case .rightOption: return "右 Option"
        case .leftCommand: return "左 Command"
        case .rightCommand: return "右 Command"
        case .leftShift: return "左 Shift"
        case .rightShift: return "右 Shift"
        }
    }
    var keyCode: UInt16 {
        switch self {
        // Caps Lock is temporarily mapped to F18 at the HID service boundary.
        case .capsLock: return 79
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }
}

struct TapShortcut: Codable, Equatable {
    var keyCode: UInt16? = nil
    var label = "不执行操作"
    var modifiers: UInt64 = 0
}

struct ModifierMapping: Codable, Equatable {
    var enabled = false
    var trigger: ModifierTrigger = .capsLock
    var tap = TapShortcut()
}

struct HyperPreferences: Codable, Equatable {
    var hyper = ModifierMapping()
    var meh = ModifierMapping(trigger: .rightOption)
    var includeShift = true
    var clicks = true
    var drags = false
    var moves = false
    var scroll = false
}

struct MacToolsConfiguration: Codable, Equatable {
    var version = 1
    var allEnabled = true
    var finderEnabled = true
    var mouseEnabled = false
    var hyperEnabled = false
    var mouse = MousePreferences()
    var hyper = HyperPreferences()
    var finderActive: Bool { allEnabled && finderEnabled }
    var mouseActive: Bool { allEnabled && mouseEnabled }
    var hyperActive: Bool { allEnabled && hyperEnabled }

    func validate() throws {
        let valid = version == 1
            && (0.1...5).contains(mouse.scrollSpeed)
            && (0...2).contains(mouse.scrollAcceleration)
            && (0.03...0.5).contains(mouse.smoothing)
            && (0.1...5).contains(mouse.pointerSpeed)
            && (-1...3).contains(mouse.pointerAcceleration)
            && !(hyper.hyper.enabled && hyper.meh.enabled && hyper.hyper.trigger == hyper.meh.trigger)
        guard valid else { throw ConfigurationError.invalid }
        for mapping in [hyper.hyper, hyper.meh] {
            guard mapping.tap.keyCode.map({ $0 <= 127 }) ?? true else { throw ConfigurationError.invalid }
        }
    }
}

enum ConfigurationError: LocalizedError {
    case invalid
    var errorDescription: String? { "配置无效，或 Hyper 与 Meh 使用了相同触发键。" }
}

enum MacToolsConfigurationStore {
    static var url: URL { ToolConfigurationStore.sharedApplicationSupportURL().appendingPathComponent("MacToolsSettings.json") }
    static func load(from url: URL = url) throws -> MacToolsConfiguration {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return MacToolsConfiguration() }
        let result = try JSONDecoder().decode(MacToolsConfiguration.self, from: data)
        try result.validate()
        return result
    }
    static func save(_ value: MacToolsConfiguration, to url: URL = url) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static var finderActive: Bool { (try? load().finderActive) ?? false }
}
