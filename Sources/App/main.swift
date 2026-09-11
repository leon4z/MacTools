import AppKit
import CoreServices
import FinderSync
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindowController: SettingsWindowController?
    private var actionLaunchObserved = false
    private var terminationSignal: DispatchSourceSignal?
    private var handledMoveRequestIDs: Set<String> = []
    private let logURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/MacTools.log")
    private lazy var moveController = MoveFeatureController { [weak self] message in
        self?.log(message)
    }

    private lazy var standaloneMenu: StandaloneMenuController = StandaloneMenuController { [weak self] action, context in
        guard let self, !self.macTools.updates.prepared, MacToolsConfigurationStore.finderActive else { return }
        switch action {
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(context.targets.map(\.path).joined(separator: "\n"), forType: .string)
        case .move:
            self.prepareForActionInvocation()
            self.moveController.begin(sourceURLs: context.targets)
        case .newFile:
            guard let directory = context.newFileDirectory else { return }
            self.prepareForActionInvocation()
            self.presentNewFile(in: directory)
        case .open(let toolID):
            guard context.targets.count == 1 else { return }
            self.prepareForActionInvocation()
            self.openSelectedURL(context.targets[0], toolID: toolID)
        }
    }

    private lazy var macTools: MacToolsModel = MacToolsModel(standalone: standaloneMenu)

    func applicationWillFinishLaunching(_ notification: Notification) {
        SharedConfigurationAccess.restore()
        AppMenu.install(in: NSApp)
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler { NSApp.terminate(nil) }
        signalSource.resume()
        terminationSignal = signalSource

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        macTools.refresh()
        macTools.updates.isBusy = { [weak self] in self?.moveController.isRunning ?? false }
        macTools.updates.prepareToInstall = { [weak self] in self?.macTools.suspendForUpdate() }
        macTools.updates.installationAborted = { [weak self] in self?.macTools.resumeAfterUpdate() }
        macTools.updates.start()
        if let menu = NSApp.mainMenu?.items.first?.submenu {
            let item = NSMenuItem(title: "检查更新…", action: #selector(AppUpdateModel.checkForUpdates(_:)), keyEquivalent: "")
            item.target = macTools.updates
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        guard !actionLaunchObserved else { return }
        if MacToolsConfigurationStore.finderActive, let pendingMove = MoveRequestStore.consumeOldestFreshRequestFromHost() {
            prepareForActionInvocation()
            handleMovePayload(pendingMove)
        } else {
            showMainWindow()
        }
    }

    private func showMainWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                macTools: macTools,
                standaloneMenu: standaloneMenu,
                openExtensionSettings: {
                    FIFinderSyncController.showExtensionManagementInterface()
                },
                restartFinder: { [weak self] in
                    self?.restartFinder()
                }
            )
        }
        settingsWindowController?.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        moveController.isRunning ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { macTools.stop() }

    private func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if moveController.isRunning {
            moveController.showCurrentOperation()
            return false
        }
        showMainWindow()
        return true
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else {
            log("received malformed URL event")
            return
        }

        handleURL(url)
    }

    private func handleURL(_ url: URL) {
        guard !macTools.updates.prepared else {
            log("ignored Finder action while installing update")
            return
        }
        guard url.scheme == "mactools" else {
            log("ignored url=unsupported scheme")
            return
        }

        guard MacToolsConfigurationStore.finderActive else { return }
        prepareForActionInvocation()

        switch url.host {
        case "open":
            handleOpenURL(url)
        case "new-file":
            handleNewFileURL(url)
        case "move":
            handleMoveURL(url)
        default:
            log("ignored url=unsupported action")
        }
    }

    private func prepareForActionInvocation() {
        actionLaunchObserved = true
        settingsWindowController?.hide()
    }

    private func handleOpenURL(_ url: URL) {
        guard let request = OpenToolRequest(url: url) else {
            log("open request missing requestID")
            return
        }

        guard let payload = OpenToolRequestStore.consumeFromHost(requestID: request.requestID) else {
            log("open request payload missing, expired, or already consumed")
            return
        }

        openSelectedURL(URL(fileURLWithPath: payload.selectedPath), toolID: payload.toolID)
    }

    private func openSelectedURL(_ selectedURL: URL, toolID: String) {
        guard let resolvedTool = ToolCatalog.resolvedAvailableTool(withID: toolID) else {
            log("open request rejected unavailable toolID=\(toolID)")
            return
        }
        let tool = resolvedTool.tool

        guard FileManager.default.fileExists(atPath: selectedURL.path) else {
            log("open request selected item missing path=\(selectedURL.path)")
            return
        }

        let appURL = resolvedTool.applicationURL

        let targetURL = ToolCatalog.targetURL(for: selectedURL, tool: tool)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.log("open failed tool=\(tool.name) target=\(targetURL.path) app=\(appURL.path) error=\(error.localizedDescription)")
                } else {
                    self.log("open succeeded tool=\(tool.name) target=\(targetURL.path) app=\(appURL.path)")
                }
            }
        }
    }

    private func handleNewFileURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let directoryPath = components?.queryItems?.first { $0.name == "directoryPath" }?.value

        guard let directoryPath else {
            log("new-file request missing directoryPath url=\(url.absoluteString)")
            return
        }

        presentNewFile(in: URL(fileURLWithPath: directoryPath, isDirectory: true))
    }

    private func presentNewFile(in directoryURL: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            log("new-file target directory missing path=\(directoryURL.path)")
            return
        }

        let dialog = NewFileDialogController()
        guard let request = dialog.run(directoryURL: directoryURL) else {
            log("new-file cancelled directory=\(directoryURL.path)")
            return
        }

        do {
            let fileURL = try NewFileService.createFile(
                named: request.fileName,
                type: request.type,
                in: directoryURL
            )
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            log("new-file succeeded path=\(fileURL.path)")
        } catch {
            log("new-file failed directory=\(directoryURL.path) file=\(request.fileName) error=\(error.localizedDescription)")
            showError("创建文件失败", detail: error.localizedDescription)
        }
    }

    private func handleMoveURL(_ url: URL) {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let requestID = queryItems.first { $0.name == "requestID" }?.value

        guard let requestID, !requestID.isEmpty else {
            log("move request missing requestID")
            showError("无法开始移动", detail: "没有收到有效的访达选择，请重新选择项目后再试。")
            return
        }

        guard !handledMoveRequestIDs.contains(requestID) else {
            log("ignored duplicate move request")
            return
        }

        guard let payload = MoveRequestStore.consumeFromHost(requestID: requestID) else {
            log("move request payload missing or invalid")
            showError("无法开始移动", detail: "移动请求已失效，请重新选择项目后再试。")
            return
        }

        handleMovePayload(payload)
    }

    private func handleMovePayload(_ payload: MoveRequestPayload) {
        guard handledMoveRequestIDs.insert(payload.requestID).inserted else { return }
        if handledMoveRequestIDs.count > 100 {
            handledMoveRequestIDs = [payload.requestID]
        }

        let sourceURLs = payload.sourcePaths.map { URL(fileURLWithPath: $0) }
        log("move request received count=\(sourceURLs.count)")
        moveController.begin(sourceURLs: sourceURLs)
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
