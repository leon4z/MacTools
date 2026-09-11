import AppKit
import Sparkle

@main enum AppUpdateTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let item = SUAppcastItem(dictionary: ["enclosure": ["url": "https://example.com/MacTools.zip", "sparkle:version": "2"]])!
        let model = AppUpdateModel()
        var busy = true
        var preparations = 0
        var resumes = 0
        var installed = 0
        model.isBusy = { busy }
        model.prepareToInstall = { preparations += 1 }
        model.installationAborted = { resumes += 1 }
        do {
            try model.updater(updater, mayPerform: .updates)
            preconditionFailure("check allowed during a file move")
        } catch {}
        busy = false
        try model.updater(updater, mayPerform: .updates)
        try model.updater(updater, shouldProceedWithUpdate: item, updateCheck: .updates)
        // A move may begin while the download is running. Defer the restart,
        // block new Finder actions, and release the input leases exactly once.
        busy = true
        precondition(model.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installed += 1 }))
        precondition(model.prepared && preparations == 1 && installed == 0)
        model.updater(updater, willInstallUpdate: item)
        precondition(preparations == 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        precondition(installed == 0)
        busy = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        precondition(installed == 1)
        model.updater(updater, didAbortWithError: NSError(domain: "test", code: 1))
        precondition(!model.prepared && resumes == 1)
        model.updater(updater, didAbortWithError: NSError(domain: "test", code: 1))
        precondition(resumes == 1, "abort must not double-resume")
        busy = true
        _ = model.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installed += 1 })
        model.updater(updater, didAbortWithError: NSError(domain: "test", code: 1))
        busy = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        precondition(installed == 1 && !model.prepared, "abort cancels a postponed restart")
        precondition(!model.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {}))
        precondition(model.prepared, "idle relaunch also blocks newly arriving Finder actions")
        print("AppUpdateTests: busy move, lease preparation, deferred restart and abort recovery passed")
    }
}
