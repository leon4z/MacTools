import AppKit

/// Owns a mouse-only tap, on LinearMouse's dedicated event run loop.
final class MouseScrollRuntime {
    private let thread = EventThread()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var processor: MouseScrollProcessor?
    private var suspended = false
    var onFailure: (() -> Void)?

    func start(_ preferences: MousePreferences) -> Bool {
        stop()
        guard preferences.scrolling else { return true }
        thread.start()
        let started = thread.performAndWait { [self] in
            suspended = false
            processor = MouseScrollProcessor(preferences: preferences, sink: { event in
                event.post(tap: .cgSessionEventTap)
                return true // Quartz has no delivery-ack API; real receiver test is separate.
            }, schedule: { [weak self] tick in
                guard let timer = self?.thread.scheduleTimer(interval: 1.0 / 120, repeats: true, handler: tick) else { return nil }
                return { timer.invalidate() }
            })
            let types: [CGEventType] = [.scrollWheel, .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<MouseScrollRuntime>.fromOpaque(context).takeUnretainedValue()
                    return owner.receive(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap, let runLoop = thread.runLoop else { processor = nil; return false }
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            guard let source else { CFMachPortInvalidate(tap); self.tap = nil; processor = nil; return false }
            CFRunLoopAddSource(runLoop.getCFRunLoop(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        } ?? false
        if !started { stop() }
        return started
    }

    // The C callback and all processor/tap state are confined to `thread`.
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            suspended = true; processor?.suspend()
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
            return Unmanaged.passUnretained(event)
        }
        guard !suspended else { return Unmanaged.passUnretained(event) }
        guard let processor else { return Unmanaged.passUnretained(event) }
        return processor.transform(event).map { Unmanaged.passUnretained($0) }
    }

    func stop() {
        _ = thread.performAndWait { [self] in
            processor?.deactivate(); processor = nil; suspended = true
            if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            if let source, let loop = thread.runLoop { CFRunLoopRemoveSource(loop.getCFRunLoop(), source, .commonModes) }
            tap = nil; source = nil
        }
        thread.stop()
    }
}
