import AppKit

/// MacTools wheel-only adapter around LinearMouse v0.11.4's engine/delivery.
/// Thread confined; no main-thread UI or window-server queries on the hot path.
final class MouseScrollProcessor {
    static let marker: Int64 = 0x4D6163546F6F6C73
    typealias EventSink = (CGEvent) -> Bool
    private let preferences: MousePreferences
    private let now: () -> TimeInterval
    private let sink: EventSink
    private let schedule: (@escaping () -> Void) -> (() -> Void)?
    private let eventFactory: (Int32, Int32) -> CGEvent?
    private let keyFactory: (CGKeyCode, Bool) -> CGEvent?
    private let physicalFlags: () -> CGEventFlags
    private var stopTimer: (() -> Void)?
    private var engine: SmoothedScrollingEngine
    private let tuning: Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Smoothed>
    private let delivery = SmoothedScrollEventDelivery()
    private var flags: CGEventFlags = []
    private var inputFlags: CGEventFlags = []
    private var pendingOriginals: [CGEvent] = []
    private var lastInputTime: TimeInterval?
    private(set) var emittedEvents = 0
    private(set) var fallbackEvents = 0
    private(set) var bypassSmoothing = false

    init(preferences: MousePreferences,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping EventSink,
         schedule: @escaping (@escaping () -> Void) -> (() -> Void)?,
         physicalFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
         keyFactory: @escaping (CGKeyCode, Bool) -> CGEvent? = { code, down in
             CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: down)
         },
         eventFactory: @escaping (Int32, Int32) -> CGEvent? = { x, y in
             CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
         }) {
        self.preferences = preferences; self.now = now; self.sink = sink
        self.schedule = schedule; self.eventFactory = eventFactory; self.keyFactory = keyFactory; self.physicalFlags = physicalFlags
        // Use upstream easeInOut, with bouncing disabled: ordinary wheel output
        // needs no private synthetic trackpad gesture sequence.
        var configuration = Scheme.Scrolling.Smoothed.Preset.easeInOut.defaultConfiguration
        configuration.speed = Decimal(preferences.scrollSpeed)
        configuration.acceleration = Decimal(preferences.scrollAcceleration)
        configuration.response = Decimal((0.68 * 0.16 / preferences.smoothing).clamped(to: 0.15...1.5))
        configuration.inertia = Decimal((0.74 * preferences.smoothing / 0.16).clamped(to: 0.1...2))
        configuration.bouncing = false
        tuning = .init(vertical: configuration, horizontal: configuration)
        engine = SmoothedScrollingEngine(smoothed: tuning)
    }

    func transform(_ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return event }
        guard event.type == .scrollWheel else {
            // Minor pointer motion must not discard each wheel tick before its
            // first animation frame. End only on actual button/key interaction.
            if [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                interruptSequence()
            }
            return event
        }
        guard preferences.scrolling else { return event }
        let view = ScrollWheelEventView(event)
        guard !view.continuous, view.scrollPhase == nil, view.momentumPhase == .none else {
            interruptSequence(); return event
        }
        let incomingFlags = event.flags
        let held = WheelModifier.allCases.filter { incomingFlags.contains($0.eventFlag) }
        // Application-owned gestures keep the original discrete event, including
        // direction and all flags. Do not smooth shortcuts owned by another app.
        if held.count > 1 || incomingFlags.contains(.maskSecondaryFn) {
            interruptSequence(); return event
        }
        if inputFlags != incomingFlags { interruptSequence() }
        let modifier = held.first
        let rule = modifier.map { preferences.modifiers[$0] }
        if rule?.action == .application { interruptSequence(); return event }
        if rule?.action == .block { interruptSequence(); return nil }
        if rule?.action == .zoom {
            interruptSequence()
            return zoom(view: view) ? nil : event
        }
        view.negate(vertically: preferences.reverseVertical, horizontally: preferences.reverseHorizontal)
        if let modifier, let rule {
            switch rule.action {
            case .changeAxis:
                // macOS may have already moved a Shift wheel onto X. Avoid a
                // second swap; other modifiers swap both axes explicitly.
                let hasX = view.deltaX != 0 || view.deltaXPt != 0 || view.deltaXFixedPt != 0 || view.ioHidScrollX != 0
                if modifier != .shift || !hasX { view.swapXY() }
            case .changeSpeed: view.scale(factor: rule.speed)
            default: break
            }
            event.flags = CGEventFlags(rawValue: incomingFlags.rawValue & ~(modifier.eventFlag.rawValue | modifier.deviceMask))
        }
        if !preferences.smooth || bypassSmoothing {
            let current = now()
            let interval = lastInputTime.map { current - $0 } ?? 1
            let boost = interval > 0 && interval < 0.2 ? 1 + preferences.scrollAcceleration * (1 - interval / 0.2) : 1
            lastInputTime = current
            inputFlags = incomingFlags
            view.scale(factor: preferences.scrollSpeed * boost)
            return event
        }
        let x = delivery.deltaXInPixels(from: view), y = delivery.deltaYInPixels(from: view)
        guard x.isFinite, y.isFinite, x != 0 || y != 0 else { return event }
        // Allocate and start the output mechanism BEFORE consuming a real tick.
        guard eventFactory(0, 0) != nil, let original = event.copy() else { failOpen(); return event }
        if pendingOriginals.count >= 64 { failOpen(); return event }
        if stopTimer == nil {
            guard let cancel = schedule({ [weak self] in self?.tick() }) else {
                bypassSmoothing = true; return event
            }
            stopTimer = cancel
        }
        inputFlags = incomingFlags
        flags = event.flags
        if (x != 0) != (y != 0) { engine.resetOtherAxis(ifExclusiveIncomingAxis: x != 0 ? .horizontal : .vertical) }
        engine.feed(deltaX: x, deltaY: y, timestamp: now(), inputKind: .wheel)
        pendingOriginals.append(original)
        return nil
    }

    private func zoom(view: ScrollWheelEventView) -> Bool {
        let vertical = delivery.deltaYInPixels(from: view)
        let delta = vertical != 0 ? vertical : delivery.deltaXInPixels(from: view)
        guard delta.isFinite, delta != 0 else { return false }
        let reversed = vertical != 0 ? preferences.reverseVertical : preferences.reverseHorizontal
        let positive = reversed ? delta < 0 : delta > 0
        let code: CGKeyCode = positive ? 69 : 78 // Keypad plus / minus, as in LinearMouse.
        // Allocate the full sequence before emitting any key. Match the existing
        // system-action dispatch: command pair, then restore physical modifiers.
        guard let down = keyFactory(code, true), let up = keyFactory(code, false),
              let restore = keyFactory(59, false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        restore.type = .flagsChanged; restore.flags = physicalFlags()
        for event in [down, up, restore] { event.setIntegerValueField(.eventSourceUserData, value: Self.marker) }
        guard sink(down) else { return false }
        if !sink(up) { _ = sink(up) } // Best-effort release; never repeat key-down.
        if !sink(restore) { _ = sink(restore) }
        return true
    }

    func tick() {
        guard let emission = engine.advance(to: now()) else {
            if !engine.isRunning { finish() }
            return
        }
        let accumulates: Bool
        switch emission.phase {
        case .touchBegan, .touchChanged, .touchEnded: accumulates = true
        default: accumulates = false
        }
        guard emission.deltaX.isFinite, emission.deltaY.isFinite,
              abs(emission.deltaX) < Double(Int32.max), abs(emission.deltaY) < Double(Int32.max),
              let event = eventFactory(0, 0) else { failOpen(); return }
        let view = ScrollWheelEventView(event)
        // Keep the upstream integer/fixed/point/IOHID representations consistent.
        delivery.setSyntheticHorizontal(emission.deltaX, on: view, accumulatesSubpixelDelta: accumulates)
        delivery.setSyntheticVertical(emission.deltaY, on: view, accumulatesSubpixelDelta: accumulates)
        if delivery.hasDelta(on: view) {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            guard sink(event) else { failOpen(); return }
            emittedEvents += 1
            pendingOriginals.removeAll(keepingCapacity: true)
        }
        if !engine.isRunning { finish() }
    }

    private func finish() {
        // Subpixel/failed-output sequences must not silently eat every tick.
        flushOriginals()
        stopTimer?(); stopTimer = nil
        delivery.resetPointDeltaRemainders()
    }
    private func flushOriginals() {
        for event in pendingOriginals {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            if sink(event) { fallbackEvents += 1 }
        }
        pendingOriginals.removeAll(keepingCapacity: true)
    }
    private func failOpen() { bypassSmoothing = true; finish(); engine = SmoothedScrollingEngine(smoothed: tuning) }
    func suspend() { failOpen() }
    private func interruptSequence() {
        // Deliver unrendered input before a new click/modifier changes its target.
        flushOriginals()
        deactivate()
    }
    func deactivate() {
        // Explicit user pause cancels the tail; never post delayed input after stop.
        stopTimer?(); stopTimer = nil
        pendingOriginals.removeAll(); delivery.resetPointDeltaRemainders()
        engine = SmoothedScrollingEngine(smoothed: tuning); flags = []; inputFlags = []; lastInputTime = nil
    }
}

private extension WheelModifier {
    var eventFlag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }
    var deviceMask: UInt64 {
        switch self {
        case .shift: return 0x6
        case .command: return 0x18
        case .option: return 0x60
        case .control: return 0x2001
        }
    }
}
