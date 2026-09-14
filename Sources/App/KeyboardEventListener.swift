import AppKit

@MainActor protocol KeyboardEventListening: AnyObject {
    func start(_ handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool
    func stop()
}

/// Owns only the keyboard mapping tap; lifecycle can be tested without global input.
@MainActor final class KeyboardEventListener: KeyboardEventListening {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
    func start(_ handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) -> Bool {
        stop()
        self.handler = handler
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<KeyboardEventListener>.fromOpaque(context).takeUnretainedValue()
                    guard let handler = owner.handler else { return Unmanaged.passUnretained(event) }
                    return handler(type, event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { self.handler = nil; return false }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { stop(); return false }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; handler = nil
    }
}
