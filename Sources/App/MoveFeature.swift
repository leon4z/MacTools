import AppKit
import Darwin
import Foundation

final class MoveFeatureController {
    private let operationQueue = DispatchQueue(label: "local.leon.FinderRightClick.move", qos: .userInitiated)
    private let lastDestinationKey = "MoveFeature.lastSuccessfulDestination"
    private let log: (String) -> Void

    private(set) var isRunning = false
    private var isChoosingDestination = false
    private var progressWindow: MoveProgressWindow?
    private var delayedProgress: DispatchWorkItem?
    private var latestProgress: (current: Int, total: Int, name: String)?
    private var processLock: MoveProcessLock?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func begin(sourceURLs: [URL]) {
        precondition(Thread.isMainThread)

        guard !isRunning else {
            showCurrentOperation()
            return
        }

        let sources = sourceURLs.map(\.standardizedFileURL)
        guard !sources.isEmpty else {
            showSimpleAlert(message: "没有可移动的项目", detail: "请重新在访达中选择文件或文件夹。")
            return
        }

        guard let processLock = MoveProcessLock.acquire() else {
            showSimpleAlert(message: "已有移动任务正在进行", detail: "请等待当前任务完成后再试。")
            return
        }
        self.processLock = processLock

        isRunning = true
        isChoosingDestination = true

        let panel = NSOpenPanel()
        panel.title = "选择目标文件夹"
        panel.message = sources.count > 1
            ? "将 \(sources.count) 个项目移动到所选文件夹"
            : "将“\(sources[0].lastPathComponent)”移动到所选文件夹"
        panel.prompt = "移动"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false

        if let lastDestination = lastSuccessfulDestination() {
            panel.directoryURL = lastDestination
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        isChoosingDestination = false

        guard response == .OK, let destinationDirectory = panel.url else {
            isRunning = false
            self.processLock = nil
            reactivateFinder()
            log("move cancelled count=\(sources.count)")
            return
        }

        reactivateFinder()
        scheduleProgressWindow()

        operationQueue.async { [weak self] in
            guard let self else { return }

            let result = MoveService.execute(
                sources: sources,
                destinationDirectory: destinationDirectory
            ) { current, total, name in
                DispatchQueue.main.async {
                    self.latestProgress = (current, total, name)
                    self.progressWindow?.update(current: current, total: total, itemName: name)
                }
            }

            DispatchQueue.main.async {
                self.finish(result: result, destinationDirectory: destinationDirectory)
            }
        }
    }

    func showCurrentOperation() {
        precondition(Thread.isMainThread)

        if isChoosingDestination, let modalWindow = NSApp.modalWindow {
            NSApp.activate(ignoringOtherApps: true)
            modalWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard isRunning else { return }
        delayedProgress?.cancel()
        showProgressWindow()
    }

    private func scheduleProgressWindow() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.showProgressWindow()
        }
        delayedProgress = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func showProgressWindow() {
        if let progressWindow {
            NSApp.activate(ignoringOtherApps: true)
            progressWindow.show()
            return
        }

        let window = MoveProgressWindow()
        progressWindow = window
        if let latestProgress {
            window.update(
                current: latestProgress.current,
                total: latestProgress.total,
                itemName: latestProgress.name
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        window.show()
    }

    private func finish(result: MoveBatchResult, destinationDirectory: URL) {
        delayedProgress?.cancel()
        delayedProgress = nil
        progressWindow?.close()
        progressWindow = nil
        latestProgress = nil
        isRunning = false
        self.processLock = nil

        if result.movedCount > 0 {
            UserDefaults.standard.set(destinationDirectory.path, forKey: lastDestinationKey)
        }

        log(
            "move finished moved=\(result.movedCount) issues=\(result.issues.count) alreadyThere=\(result.alreadyThere.count)"
        )

        if result.hasVisibleResult {
            showResult(result)
        } else {
            reactivateFinder()
        }
    }

    private func lastSuccessfulDestination() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastDestinationKey) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func showResult(_ result: MoveBatchResult) {
        let details = result.issues.map { issue in
            "\(issue.sourceURL.lastPathComponent)：\(issue.reason)"
        } + result.alreadyThere.map { url in
            "\(url.lastPathComponent)：已在目标位置"
        }

        let copyDetails = result.issues.map { issue in
            "\(issue.sourceURL.path)\n原因：\(issue.reason)"
        } + result.alreadyThere.map { url in
            "\(url.path)\n原因：已在目标位置"
        }

        let alert = NSAlert()
        if result.issues.isEmpty, result.movedCount == 0, !result.alreadyThere.isEmpty {
            alert.messageText = "所选项目已在此位置"
            alert.alertStyle = .informational
        } else {
            let warningCount = result.issues.filter(\.destinationCopyRetained).count
            let notMovedCount = result.issues.count - warningCount + result.alreadyThere.count
            var summaryParts = ["完成 \(result.movedCount) 项"]
            if notMovedCount > 0 {
                summaryParts.append("\(notMovedCount) 项未移动")
            }
            if warningCount > 0 {
                summaryParts.append("\(warningCount) 项需要检查")
            }
            alert.messageText = summaryParts.joined(separator: "，")
            alert.alertStyle = result.issues.isEmpty ? .informational : .warning
        }
        alert.informativeText = "未移动项目及原因："
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "复制详情")
        alert.accessoryView = resultAccessoryView(text: details.joined(separator: "\n"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(copyDetails.joined(separator: "\n\n"), forType: .string)
        }
        reactivateFinder()
    }

    private func resultAccessoryView(text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView
        return scrollView
    }

    private func showSimpleAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func reactivateFinder() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }
}

private final class MoveProcessLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() -> MoveProcessLock? {
        guard let cachesDirectory = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        let directory = cachesDirectory.appendingPathComponent("FinderRightClick", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let lockURL = directory.appendingPathComponent("move.lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { pathPointer in
            pathPointer.map { Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return MoveProcessLock(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

private final class MoveProgressWindow {
    private let window: NSPanel
    private let itemLabel: NSTextField
    private let countLabel: NSTextField

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "正在移动"
        window.isReleasedWhenClosed = false
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        row.addArrangedSubview(spinner)

        itemLabel = NSTextField(labelWithString: "正在准备…")
        itemLabel.font = .systemFont(ofSize: 14, weight: .medium)
        itemLabel.lineBreakMode = .byTruncatingMiddle
        row.addArrangedSubview(itemLabel)
        root.addArrangedSubview(row)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(countLabel)

        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 392).isActive = true
        itemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func update(current: Int, total: Int, itemName: String) {
        itemLabel.stringValue = itemName
        countLabel.stringValue = total > 0 ? "第 \(current)/\(total) 项" : ""
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
