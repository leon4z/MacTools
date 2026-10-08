import AppKit
import Combine
import ServiceManagement

enum LoginItemState: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LoginItemManaging: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

private final class SystemLoginItemManager: LoginItemManaging {
    private let service = SMAppService.mainApp

    var state: LoginItemState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
final class ApplicationSettingsModel: ObservableObject {
    static let hideDockIconKey = "application.hideDockIcon"

    @Published private(set) var loginItemState: LoginItemState
    @Published private(set) var hideDockIcon: Bool
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let loginItem: LoginItemManaging
    private let applyDockVisibility: @MainActor (Bool) -> Bool
    private let openLoginItemSettingsAction: @MainActor () -> Void

    init(
        defaults: UserDefaults = .standard,
        loginItem: LoginItemManaging = SystemLoginItemManager(),
        applyDockVisibility: @escaping @MainActor (Bool) -> Bool = { hidden in
            let target: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
            return NSApp.activationPolicy() == target || NSApp.setActivationPolicy(target)
        },
        openLoginItemSettings: @escaping @MainActor () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.applyDockVisibility = applyDockVisibility
        self.openLoginItemSettingsAction = openLoginItemSettings
        loginItemState = loginItem.state
        hideDockIcon = defaults.bool(forKey: Self.hideDockIconKey)
    }

    var launchAtLogin: Bool { loginItemState == .enabled }
    var requiresLoginItemApproval: Bool { loginItemState == .requiresApproval }

    var loginItemStatusText: String {
        switch loginItemState {
        case .notRegistered:
            return "登录时启动已关闭。"
        case .enabled:
            return "登录后将在后台启动，不自动打开设置窗口。"
        case .requiresApproval:
            return "等待你在系统设置的“登录项”中允许 MacTools。"
        case .notFound:
            return "系统未找到 MacTools 登录项，请确认应用位于稳定位置后重试。"
        }
    }

    func applyStoredPresentation() {
        guard hideDockIcon else { return }
        guard applyDockVisibility(true) else {
            errorMessage = "无法应用 Dock 图标设置。"
            return
        }
    }

    func refreshLoginItemState() {
        loginItemState = loginItem.state
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                switch loginItem.state {
                case .enabled:
                    break
                case .requiresApproval:
                    openLoginItemSettingsAction()
                case .notRegistered, .notFound:
                    try loginItem.register()
                }
            } else {
                switch loginItem.state {
                case .enabled, .requiresApproval:
                    try loginItem.unregister()
                case .notRegistered, .notFound:
                    break
                }
            }
        } catch {
            errorMessage = "无法更新登录项：\(error.localizedDescription)"
        }
        refreshLoginItemState()
    }

    func setHideDockIcon(_ hidden: Bool) {
        errorMessage = nil
        guard applyDockVisibility(hidden) else {
            errorMessage = "无法更新 Dock 图标显示状态。"
            return
        }
        defaults.set(hidden, forKey: Self.hideDockIconKey)
        hideDockIcon = hidden
    }

    func openLoginItemSettings() {
        openLoginItemSettingsAction()
    }
}
