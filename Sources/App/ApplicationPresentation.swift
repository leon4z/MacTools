import Foundation

enum InitialWindowPolicy {
    static func shouldShowWindow(launchedAsLoginItem: Bool, actionLaunchObserved: Bool) -> Bool {
        !launchedAsLoginItem && !actionLaunchObserved
    }
}

struct MenuBarPresentation: Equatable {
    let statusTitle: String
    let masterToggleEnabled: Bool
    let masterToggleOn: Bool
    let iconDimmed: Bool

    init(configurationLoaded: Bool, allEnabled: Bool) {
        if !configurationLoaded {
            statusTitle = "配置需要重新连接"
            masterToggleEnabled = false
            masterToggleOn = false
            iconDimmed = true
        } else if allEnabled {
            statusTitle = "增强开关已开启"
            masterToggleEnabled = true
            masterToggleOn = true
            iconDimmed = false
        } else {
            statusTitle = "全部增强已停用"
            masterToggleEnabled = true
            masterToggleOn = false
            iconDimmed = true
        }
    }
}
