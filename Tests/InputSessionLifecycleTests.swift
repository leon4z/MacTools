import AppKit

@main enum InputSessionLifecycleTests {
    @MainActor static func main() {
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        let lifecycle = InputSessionLifecycle(workspace: workspace, distributed: distributed)
        var stopped = 0, resumed = 0
        lifecycle.onSuspend = { stopped += 1 }
        lifecycle.onResume = { resumed += 1 }
        // Plain screen lock emits no workspace session notification.
        distributed.post(name: InputSessionLifecycle.screenLocked, object: nil)
        precondition(!lifecycle.canResume && stopped == 1 && resumed == 0)
        distributed.post(name: InputSessionLifecycle.screenUnlocked, object: nil)
        precondition(lifecycle.canResume && resumed == 1)
        // Wake before unlock and unlock before wake both remain gated.
        for wakeFirst in [true, false] {
            distributed.post(name: InputSessionLifecycle.screenLocked, object: nil)
            workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            let before = resumed
            if wakeFirst { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
            else { distributed.post(name: InputSessionLifecycle.screenUnlocked, object: nil) }
            precondition(!lifecycle.canResume && resumed == before)
            if wakeFirst { distributed.post(name: InputSessionLifecycle.screenUnlocked, object: nil) }
            else { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
            precondition(lifecycle.canResume && resumed == before + 1)
        }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        distributed.post(name: InputSessionLifecycle.screenLocked, object: nil)
        let before = resumed
        distributed.post(name: InputSessionLifecycle.screenUnlocked, object: nil)
        precondition(!lifecycle.canResume && resumed == before)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        precondition(lifecycle.canResume && resumed == before + 1)
        print("InputSessionLifecycleTests: lock without session switch, both wake/unlock orders, inactive-session gate passed; isolated notifications only")
    }
}
