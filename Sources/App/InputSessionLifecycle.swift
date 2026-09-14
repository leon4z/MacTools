import AppKit

/// Screen lock is distinct from fast user switching and whole-machine sleep.
/// Lock notifications supplement (not replace) per-event physical-key reconciliation.
@MainActor final class InputSessionLifecycle {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    private var sleeping = false
    private var inactive = false
    private var locked = false
    var canResume: Bool { !sleeping && !inactive && !locked }
    var onSuspend: (() -> Void)?
    var onResume: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.sleeping = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.inactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.inactive = false }
        observe(distributed, Self.screenLocked) { $0.locked = true }
        observe(distributed, Self.screenUnlocked) { $0.locked = false }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         change: @escaping (InputSessionLifecycle) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                if self.canResume { self.onResume?() } else { self.onSuspend?() }
            }
        }
        observers.append((center, token))
    }
    deinit { for (center, token) in observers { center.removeObserver(token) } }
}
