import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let model: MacToolsModel
    private let updates: AppUpdateModel
    private let openSettingsAction: () -> Void
    private let menu = NSMenu(title: "MacTools")
    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let masterToggleItem = NSMenuItem(title: "启用全部增强", action: nil, keyEquivalent: "")
    private let checkUpdatesItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
    private var subscriptions = Set<AnyCancellable>()

    init(model: MacToolsModel, openSettings: @escaping () -> Void) {
        self.model = model
        updates = model.updates
        openSettingsAction = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = MacToolsMenuBarIcon.makeImage()
            button.toolTip = "MacTools"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "打开 MacTools 设置", action: #selector(openSettings(_:)), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        masterToggleItem.action = #selector(toggleAllEnhancements(_:))
        masterToggleItem.target = self
        menu.addItem(masterToggleItem)
        menu.addItem(.separator())

        checkUpdatesItem.action = #selector(checkForUpdates(_:))
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 MacTools", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        model.$configuration
            .combineLatest(model.$configurationLoaded)
            .sink { [weak self] configuration, loaded in
                self?.apply(MenuBarPresentation(configurationLoaded: loaded, allEnabled: configuration.allEnabled))
            }
            .store(in: &subscriptions)
        updates.$canCheck
            .sink { [weak self] in self?.checkUpdatesItem.isEnabled = $0 }
            .store(in: &subscriptions)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func apply(_ presentation: MenuBarPresentation) {
        statusLineItem.title = presentation.statusTitle
        masterToggleItem.isEnabled = presentation.masterToggleEnabled
        masterToggleItem.state = presentation.masterToggleOn ? .on : .off
        statusItem.button?.appearsDisabled = presentation.iconDimmed
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            openSettingsAction()
            return
        }

        statusItem.popUpMenu(menu)
    }

    @objc private func openSettings(_ sender: Any?) {
        openSettingsAction()
    }

    @objc private func toggleAllEnhancements(_ sender: Any?) {
        let enabled = !model.configuration.allEnabled
        model.update { $0.allEnabled = enabled }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updates.checkForUpdates(sender)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}

private enum MacToolsMenuBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()

            for rect in [
                NSRect(x: 1.5, y: 10.2, width: 6.2, height: 6.2),
                NSRect(x: 1.5, y: 1.6, width: 6.2, height: 6.2),
                NSRect(x: 10.1, y: 1.6, width: 6.2, height: 6.2),
            ] {
                NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6).fill()
            }

            let sparkle = NSBezierPath()
            sparkle.move(to: NSPoint(x: 12.95, y: 17.2))
            sparkle.curve(
                to: NSPoint(x: 8.7, y: 12.95),
                controlPoint1: NSPoint(x: 12.45, y: 14.55),
                controlPoint2: NSPoint(x: 11.6, y: 13.55)
            )
            sparkle.curve(
                to: NSPoint(x: 12.95, y: 8.7),
                controlPoint1: NSPoint(x: 11.6, y: 12.35),
                controlPoint2: NSPoint(x: 12.45, y: 11.35)
            )
            sparkle.curve(
                to: NSPoint(x: 17.2, y: 12.95),
                controlPoint1: NSPoint(x: 13.45, y: 11.35),
                controlPoint2: NSPoint(x: 14.3, y: 12.35)
            )
            sparkle.curve(
                to: NSPoint(x: 12.95, y: 17.2),
                controlPoint1: NSPoint(x: 14.3, y: 13.55),
                controlPoint2: NSPoint(x: 13.45, y: 14.55)
            )
            sparkle.close()
            sparkle.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacTools"
        return image
    }
}
