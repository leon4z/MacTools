import AppKit
import ApplicationServices

/// Read only, bounded AX lookup. No selection changes, click replay, clipboard
/// tricks, or fallback to a previously used directory.
enum FinderAccessibilityContext {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "无法确定鼠标下的访达项目。请在文件列表或图标区域重试；搜索结果、侧边栏和工具栏暂不支持。"
        }
    }

    static func capture(at point: CGPoint, finderPID: pid_t) throws -> StandaloneMenuContext {
        let reader = Reader()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { throw Failure.unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == finderPID else { throw Failure.unavailable }
        let finder = AXUIElementCreateApplication(finderPID)
        AXUIElementSetMessagingTimeout(finder, 0.12)

        var chain = [AXUIElement]()
        var cursor: AXUIElement? = hit
        for _ in 0..<18 {
            guard let element = cursor else { break }
            chain.append(element)
            if reader.string(element, kAXRoleAttribute) == kAXWindowRole { break }
            cursor = reader.element(element, kAXParentAttribute)
        }
        guard !reader.exhausted,
              let window = chain.first(where: { reader.string($0, kAXRoleAttribute) == kAXWindowRole }),
              !chain.contains(where: {
                  let role = reader.string($0, kAXRoleAttribute)
                  let identifier = reader.string($0, kAXIdentifierAttribute).lowercased()
                  let description = reader.string($0, kAXDescriptionAttribute).lowercased()
                  return role == kAXToolbarRole || identifier.contains("sidebar")
                      || description == "sidebar" || description == "边栏" || description == "側邊欄"
              }),
              let content = chain.first(where: {
                  [kAXOutlineRole, kAXListRole, kAXTableRole, kAXBrowserRole].contains(reader.string($0, kAXRoleAttribute))
              }) else { throw Failure.unavailable }

        let directory = reader.url(window, kAXDocumentAttribute)
        // Inspect only the hit item/row. Never descend through a whole list when
        // the user clicked blank space, or its first item would become the target.
        var itemURL: URL?
        for element in chain {
            if CFEqual(element, content) { break }
            if let url = reader.url(element, kAXURLAttribute) { itemURL = url; break }
            if reader.string(element, kAXRoleAttribute) == kAXRowRole {
                let urls = reader.fileURLs(in: element, depth: 5)
                guard urls.count <= 1 else { throw Failure.unavailable }
                itemURL = urls.first
                // An unresolved row is not blank space.
                guard itemURL != nil else { throw Failure.unavailable }
                break
            }
        }

        var selection = [URL]()
        if itemURL != nil {
            guard let selected = StandaloneSelection.resolve(reader.selection(content, kAXSelectedRowsAttribute), fallback: {
                reader.selection(content, kAXSelectedChildrenAttribute)
            }) else { throw Failure.unavailable }
            guard selected.count <= 500 else { throw Failure.unavailable }
            for row in selected {
                let urls = reader.fileURLs(in: row, depth: 5)
                guard urls.count == 1 else { throw Failure.unavailable }
                selection.append(urls[0])
            }
        }
        // A leaf with no URL may be an unresolved icon. Only a direct hit on a
        // known content container counts as background, never an arbitrary child.
        let backgroundConfirmed = itemURL == nil && CFEqual(hit, content)
        guard !reader.exhausted,
              let result = StandaloneMenuContext.resolve(directory: directory, hit: itemURL, selection: selection, backgroundHitConfirmed: backgroundConfirmed, isDirectory: {
                  (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
              }) else { throw Failure.unavailable }
        return result
    }

    private final class Reader {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var calls = 0
        var exhausted = false
        var lastError: AXError = .success
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard calls < 350, ProcessInfo.processInfo.systemUptime < deadline else {
                exhausted = true
                lastError = .cannotComplete
                return nil
            }
            calls += 1
            var result: CFTypeRef?
            lastError = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            guard lastError == .success else { return nil }
            return result
        }
        func string(_ element: AXUIElement, _ name: String) -> String { value(element, name) as? String ?? "" }
        func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
            guard let result = value(element, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
            optionalElements(element, name) ?? []
        }
        func optionalElements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
            guard let array = value(element, name) as? [AnyObject],
                  array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return array.map { $0 as! AXUIElement }
        }
        func selection(_ element: AXUIElement, _ name: String) -> StandaloneSelectionRead<AXUIElement> {
            if let items = optionalElements(element, name) { return .values(items) }
            if lastError == .attributeUnsupported || lastError == .notImplemented { return .unsupported }
            return .failed
        }
        func url(_ element: AXUIElement, _ name: String) -> URL? {
            let raw = value(element, name)
            if let url = raw as? URL, url.isFileURL { return url }
            if let string = raw as? String, let url = URL(string: string), url.isFileURL { return url }
            return nil
        }
        func fileURLs(in element: AXUIElement, depth: Int) -> [URL] {
            if let url = url(element, kAXURLAttribute) { return [url] }
            guard depth > 0 else { return [] }
            var result = [URL]()
            for child in elements(element, kAXChildrenAttribute) {
                for url in fileURLs(in: child, depth: depth - 1) where !result.contains(url) { result.append(url) }
                if result.count > 1 || exhausted { break }
            }
            return result
        }
    }
}
