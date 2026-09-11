import Foundation

/// A frozen Finder target. Blank space never inherits an old file selection.
struct StandaloneMenuContext: Equatable {
    let targets: [URL]
    let isBackground: Bool
    let newFileDirectory: URL?

    static func resolve(
        directory: URL?, hit: URL?, selection: [URL], backgroundHitConfirmed: Bool = false,
        isDirectory: (URL) -> Bool
    ) -> StandaloneMenuContext? {
        func clean(_ url: URL) -> URL? {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/") else { return nil }
            return url.standardizedFileURL
        }
        if let hit {
            guard let item = clean(hit), selection.count <= 500 else { return nil }
            var unique = [URL]()
            for url in selection {
                guard let url = clean(url) else { return nil }
                if !unique.contains(url) { unique.append(url) }
            }
            let targets = unique.contains(item) ? unique : [item]
            let newDirectory = targets.count == 1
                ? (isDirectory(item) ? item : item.deletingLastPathComponent()) : nil
            return Self(targets: targets, isBackground: false, newFileDirectory: newDirectory)
        }
        guard backgroundHitConfirmed, let directory, let folder = clean(directory), isDirectory(folder) else { return nil }
        return Self(targets: [folder], isBackground: true, newFileDirectory: folder)
    }
}

enum StandaloneMenuTrigger: String, CaseIterable, Identifiable {
    case option, command
    var id: String { rawValue }
    var title: String { self == .option ? "Option＋右键" : "Command＋右键" }
}

enum StandaloneSelectionRead<Element> {
    case values([Element]), unsupported, failed
}

enum StandaloneSelection {
    /// Fallback is allowed only for an unsupported attribute, not a timeout,
    /// invalid value, or communication failure. A successful empty list is final.
    static func resolve<T>(_ primary: StandaloneSelectionRead<T>, fallback: () -> StandaloneSelectionRead<T>) -> [T]? {
        switch primary {
        case .values(let values): return values
        case .failed: return nil
        case .unsupported:
            if case .values(let values) = fallback() { return values }
            return nil
        }
    }
}

/// Pure gesture state: swallow only the matching down/up pair, even if modifiers
/// are released before the mouse button. A changed setting cancels pending work.
struct StandaloneMenuGesture {
    enum Decision: Equatable { case pass, consume, invoke }
    private(set) var pressed = false
    mutating func down(matches: Bool, isFinder: Bool, busy: Bool) -> Decision {
        guard !pressed, matches, isFinder, !busy else { return .pass }
        pressed = true
        return .consume
    }
    mutating func up() -> Decision {
        guard pressed else { return .pass }
        pressed = false
        return .invoke
    }
    mutating func reset() { pressed = false }
}
