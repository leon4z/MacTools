import Foundation

@main
enum ApplicationSettingsTests {
    @MainActor
    static func main() throws {
        try testPresentationDefaultsAndPersistence()
        try testFailedDockChangeDoesNotPersist()
        try testLoginItemRegistrationAndRemoval()
        try testApprovalAndExternalStateRefresh()
        try testRegistrationErrorIsReported()
        try testInitialWindowPolicy()
        try testMenuBarPresentation()
        print("ApplicationSettingsTests: all tests passed")
    }

    @MainActor
    private static func testPresentationDefaultsAndPersistence() throws {
        let suite = makeDefaults("presentation")
        let defaults = suite.defaults
        defer { clear(suite) }
        var applied: [Bool] = []
        let model = ApplicationSettingsModel(
            defaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockVisibility: { applied.append($0); return true },
            openLoginItemSettings: {}
        )

        try expect(!model.hideDockIcon, "Dock icon is visible by default")
        model.applyStoredPresentation()
        try expect(applied.isEmpty, "the default regular activation policy is not redundantly reapplied")

        model.setHideDockIcon(true)
        try expect(model.hideDockIcon, "Dock preference updates immediately")
        try expect(defaults.bool(forKey: ApplicationSettingsModel.hideDockIconKey), "Dock preference is persisted")
        try expect(applied == [true], "Dock activation policy receives the new preference")

        var restored: [Bool] = []
        let restoredModel = ApplicationSettingsModel(
            defaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockVisibility: { restored.append($0); return true },
            openLoginItemSettings: {}
        )
        restoredModel.applyStoredPresentation()
        try expect(restored == [true], "a stored hidden-Dock preference is restored on launch")
    }

    @MainActor
    private static func testFailedDockChangeDoesNotPersist() throws {
        let suite = makeDefaults("dock-failure")
        let defaults = suite.defaults
        defer { clear(suite) }
        let model = ApplicationSettingsModel(
            defaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockVisibility: { _ in false },
            openLoginItemSettings: {}
        )

        model.setHideDockIcon(true)
        try expect(!model.hideDockIcon, "failed Dock change leaves published state unchanged")
        try expect(defaults.object(forKey: ApplicationSettingsModel.hideDockIconKey) == nil,
                   "failed Dock change is not persisted")
        try expect(model.errorMessage != nil, "failed Dock change is reported")
    }

    @MainActor
    private static func testLoginItemRegistrationAndRemoval() throws {
        let suite = makeDefaults("login-toggle")
        let defaults = suite.defaults
        defer { clear(suite) }
        let loginItem = FakeLoginItem()
        let model = ApplicationSettingsModel(
            defaults: defaults,
            loginItem: loginItem,
            applyDockVisibility: { _ in true },
            openLoginItemSettings: {}
        )

        try expect(!model.launchAtLogin, "login item is off by default")
        model.setLaunchAtLogin(true)
        try expect(loginItem.registerCount == 1, "enabling registers the main app")
        try expect(model.launchAtLogin, "enabled system state drives the toggle")

        model.setLaunchAtLogin(false)
        try expect(loginItem.unregisterCount == 1, "disabling unregisters the main app")
        try expect(!model.launchAtLogin, "unregistered system state drives the toggle")
    }

    @MainActor
    private static func testApprovalAndExternalStateRefresh() throws {
        let suite = makeDefaults("approval")
        let defaults = suite.defaults
        defer { clear(suite) }
        let loginItem = FakeLoginItem(state: .requiresApproval)
        var settingsOpenCount = 0
        let model = ApplicationSettingsModel(
            defaults: defaults,
            loginItem: loginItem,
            applyDockVisibility: { _ in true },
            openLoginItemSettings: { settingsOpenCount += 1 }
        )

        try expect(!model.launchAtLogin, "approval-required state is not reported as enabled")
        try expect(model.requiresLoginItemApproval, "approval-required state is exposed to the UI")
        model.setLaunchAtLogin(true)
        try expect(settingsOpenCount == 1, "enabling an approval-required item opens System Settings")
        try expect(loginItem.registerCount == 0, "approval-required item is not registered repeatedly")

        loginItem.state = .enabled
        model.refreshLoginItemState()
        try expect(model.launchAtLogin, "external System Settings changes are reflected after refresh")
    }

    @MainActor
    private static func testRegistrationErrorIsReported() throws {
        let suite = makeDefaults("registration-error")
        let defaults = suite.defaults
        defer { clear(suite) }
        let loginItem = FakeLoginItem()
        loginItem.registerError = TestError.failed
        let model = ApplicationSettingsModel(
            defaults: defaults,
            loginItem: loginItem,
            applyDockVisibility: { _ in true },
            openLoginItemSettings: {}
        )

        model.setLaunchAtLogin(true)
        try expect(!model.launchAtLogin, "failed registration leaves login disabled")
        try expect(model.errorMessage?.contains("无法更新登录项") == true, "registration failure is reported")
    }

    private static func testInitialWindowPolicy() throws {
        try expect(InitialWindowPolicy.shouldShowWindow(launchedAsLoginItem: false, actionLaunchObserved: false),
                   "a regular launch shows settings")
        try expect(!InitialWindowPolicy.shouldShowWindow(launchedAsLoginItem: true, actionLaunchObserved: false),
                   "an explicit login-item launch stays silent")
        try expect(!InitialWindowPolicy.shouldShowWindow(launchedAsLoginItem: false, actionLaunchObserved: true),
                   "a Finder action launch does not reveal settings")
    }

    private static func testMenuBarPresentation() throws {
        let unavailable = MenuBarPresentation(configurationLoaded: false, allEnabled: true)
        try expect(unavailable.statusTitle == "配置需要重新连接", "unavailable configuration has a precise status")
        try expect(!unavailable.masterToggleEnabled && !unavailable.masterToggleOn && unavailable.iconDimmed,
                   "unavailable configuration disables menu actions")
        try expect(MenuBarPresentation(configurationLoaded: true, allEnabled: true).statusTitle == "增强开关已开启",
                   "enabled configuration has a precise status")
        try expect(MenuBarPresentation(configurationLoaded: true, allEnabled: false).iconDimmed,
                   "disabled enhancements dim the menu icon")
    }

    private static func makeDefaults(_ name: String) -> DefaultsSuite {
        let suiteName = "MacTools.ApplicationSettingsTests.\(name).\(UUID().uuidString)"
        return DefaultsSuite(name: suiteName, defaults: UserDefaults(suiteName: suiteName)!)
    }

    private static func clear(_ suite: DefaultsSuite) {
        suite.defaults.removePersistentDomain(forName: suite.name)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private final class FakeLoginItem: LoginItemManaging {
    var state: LoginItemState
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(state: LoginItemState = .notRegistered) {
        self.state = state
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        state = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        state = .notRegistered
    }
}

private enum TestError: LocalizedError {
    case failed
    var errorDescription: String? { "test failure" }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct DefaultsSuite {
    let name: String
    let defaults: UserDefaults
}
