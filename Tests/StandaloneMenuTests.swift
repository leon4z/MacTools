import Foundation

@main
enum StandaloneMenuTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/fixture/iCloud folder", isDirectory: true)
        let a = directory.appendingPathComponent("甲 a.md")
        let b = directory.appendingPathComponent("乙.md")
        let child = directory.appendingPathComponent("child", isDirectory: true)
        func context(_ hit: URL?, _ selection: [URL], folder: URL? = directory) -> StandaloneMenuContext? {
            StandaloneMenuContext.resolve(directory: folder, hit: hit, selection: selection, backgroundHitConfirmed: hit == nil) { $0 == directory || $0 == child }
        }
        try expect(context(a, [a,b])?.targets == [a,b], "hit within selection preserves all selected items")
        try expect(context(a, [a,b])?.newFileDirectory == nil, "multiple selection hides new file")
        try expect(context(b, [a])?.targets == [b], "unselected hit replaces old selection")
        try expect(context(a, [])?.newFileDirectory == directory, "file targets containing directory")
        try expect(context(child, [a])?.newFileDirectory == child, "directory targets its contents")
        try expect(context(nil, [a,b])?.targets == [directory], "blank ignores stale selection")
        try expect(context(nil, [a])?.isBackground == true, "background has no move action")
        try expect(context(nil, [], folder: nil) == nil, "unknown blank directory fails closed")
        try expect(StandaloneMenuContext.resolve(directory: directory, hit: nil, selection: [a], isDirectory: { _ in true }) == nil,
                   "unresolved item is never treated as background merely because its URL is missing")
        try expect(context(a, [], folder: nil)?.targets == [a], "explicit item does not need a fallback directory")
        try expect(context(a, [a,a,b])?.targets == [a,b], "duplicate selection is collapsed")
        try expect(context(URL(string: "https://example.com/a")!, []) == nil, "reject remote hit URL")
        try expect(context(URL(string: "file://remote/path")!, []) == nil, "reject remote file host")
        try expect(context(a, [URL(string: "https://example.com")!]) == nil, "reject partial invalid selection")
        try expect(context(a, Array(repeating: a, count: 501)) == nil, "oversized selection fails closed")
        let frozen = context(a, [a,b])!
        _ = context(child, [])
        try expect(frozen.targets == [a,b], "snapshot remains immutable after other invocations")

        var gesture = StandaloneMenuGesture()
        try expect(gesture.down(matches: false, isFinder: true, busy: false) == .pass, "native right click passes through")
        try expect(gesture.up() == .pass, "unclaimed mouse up passes through")
        try expect(gesture.down(matches: true, isFinder: false, busy: false) == .pass, "other apps untouched")
        try expect(gesture.down(matches: true, isFinder: true, busy: true) == .pass, "no overlapping invocation")
        try expect(gesture.down(matches: true, isFinder: true, busy: false) == .consume, "trigger consumes down")
        try expect(gesture.up() == .invoke, "paired up invokes even after modifier release")
        try expect(gesture.up() == .pass, "gesture cannot replay")
        _ = gesture.down(matches: true, isFinder: true, busy: false)
        gesture.reset()
        try expect(gesture.up() == .pass, "disable cancels gesture")
        var fallbackCalled = false
        let failed: [URL]? = StandaloneSelection.resolve(.failed) {
            fallbackCalled = true
            return .values([a])
        }
        try expect(failed == nil && !fallbackCalled, "selection communication failure never falls back to a partial selection")
        let empty: [URL]? = StandaloneSelection.resolve(.values([])) {
            fallbackCalled = true
            return .values([a])
        }
        try expect(empty == [] && !fallbackCalled, "successful empty selection is not confused with unsupported attribute")
        try expect(StandaloneSelection.resolve(StandaloneSelectionRead<URL>.unsupported) { .values([a,b]) } == [a,b], "unsupported selection attribute uses alternate API")
        try expect(StandaloneSelection.resolve(StandaloneSelectionRead<URL>.unsupported) { .failed } == nil, "fallback failure rejects target")
        print("StandaloneMenuTests: 28 checks passed")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "StandaloneMenuTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
