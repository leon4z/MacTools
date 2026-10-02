import Foundation

@main enum FinderExtensionStatusTests {
    static func main() {
        let id = "com.leon4z.MacTools.FinderExtension"
        let enabled = FinderExtensionStatus.parse("+    \(id)(1.7.2)\n", identifier: id)
        precondition(enabled == .enabled)
        // The observed bug: the API says false while PlugInKit confirms enablement.
        precondition(FinderExtensionStatus.resolve(registry: enabled, apiEnabled: false) == .enabled)
        let disabled = FinderExtensionStatus.parse("-    \(id)(1.7.3)\n", identifier: id)
        precondition(disabled == .disabled)
        precondition(FinderExtensionStatus.resolve(registry: disabled, apiEnabled: true) == .disabled)
        for text in ["", "   \(id)(1.7.2)", "? \(id)(1.7.2)", "= \(id)(1.7.2)", "! \(id)(1.7.2)",
                     "+ \(id).Other(1.7.2)", "+ \(id)(1.7.2)\n- \(id)(1.7.3)"] {
            precondition(FinderExtensionStatus.parse(text, identifier: id) == .unknown)
        }
        precondition(FinderExtensionStatus.parse(" \n+\t\(id)(1.7.3)\n unrelated line", identifier: id) == .enabled)
        precondition(FinderExtensionStatus.resolve(registry: .unknown, apiEnabled: false) == .unknown)
        precondition(FinderExtensionStatus.resolve(registry: .unknown, apiEnabled: true) == .enabled)
        print("FinderExtensionStatusTests: enabled/disabled elections, API disagreement, uncertain results and exact identifier matching passed")
    }
}
