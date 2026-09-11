import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns transport, signature verification, installation and its standard UI.
@MainActor
final class AppUpdateModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var status = "手动检查新版本，安装前会显示更新说明。"
    var isBusy: () -> Bool = { false }
    var prepareToInstall: () -> Void = {}
    var installationAborted: () -> Void = {}
    private(set) var prepared = false
    private var observations: [NSKeyValueObservation] = []
    private var relaunchTimer: Timer?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                Task { @MainActor in self?.canCheck = change.newValue ?? false }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                Task { @MainActor in self?.automaticChecks = change.newValue ?? false }
            }
        ]
        controller.startUpdater()
    }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        controller.checkForUpdates(sender)
    }
    func setAutomaticChecks(_ value: Bool) {
        controller.updater.automaticallyChecksForUpdates = value
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        try requireIdle()
    }
    private func requireIdle() throws {
        if isBusy() {
            throw NSError(domain: "MacTools.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "文件正在移动，请完成后再更新 MacTools。"])
        }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beginInstallation()
    }
    private func beginInstallation() {
        guard !prepared else { return }
        prepared = true
        prepareToInstall()
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        beginInstallation()
        guard isBusy() else { return false }
        status = "等待文件移动完成后安装更新。"
        relaunchTimer?.invalidate()
        relaunchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard !self.isBusy() else { return }
                timer.invalidate()
                self.relaunchTimer = nil
                installHandler()
            }
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "发现新版本 \(item.displayVersionString)。"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { status = "当前已是最新版本。" }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        status = error.localizedDescription
        relaunchTimer?.invalidate()
        relaunchTimer = nil
        if prepared { prepared = false; installationAborted() }
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var model: AppUpdateModel
    var body: some View {
        GroupBox("应用更新") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("自动检查更新", isOn: Binding(
                    get: { model.automaticChecks }, set: { model.setAutomaticChecks($0) }))
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Button("检查更新…") { model.checkForUpdates() }.disabled(!model.canCheck)
                Text("更新包经过签名校验；下载和安装由你确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
