import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private let model = ToolSettingsModel()
    private let window: NSWindow

    init(macTools: MacToolsModel, standaloneMenu: StandaloneMenuController, openExtensionSettings: @escaping () -> Void, restartFinder: @escaping () -> Void) {
        let rootView = MacToolsRootView(
            model: model,
            macTools: macTools,
            standaloneMenu: standaloneMenu,
            openExtensionSettings: openExtensionSettings,
            restartFinder: restartFinder
        )
        let hostingController = NSHostingController(rootView: rootView)
        window = NSWindow(contentViewController: hostingController)
        window.title = "MacTools"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1060, height: 720))
        window.minSize = NSSize(width: 960, height: 640)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        // Keep content below the standard title bar; no toolbar extends into it.
    }

    func show() {
        model.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window.orderOut(nil)
    }
}

@MainActor
final class ToolSettingsModel: ObservableObject {
    @Published private(set) var tools: [ConfiguredTool]
    @Published var errorMessage: String?

    init() {
        tools = ToolCatalog.configuredTools()
    }

    func reload() {
        tools = ToolCatalog.configuredTools()
    }

    func addApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择已安装的 App"
        panel.message = "所选 App 将显示在 Finder 的“用工具打开”菜单中。"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }

        var updated = tools
        for url in panel.urls {
            guard let selectedTool = ToolCatalog.configuredTool(forApplicationURL: url) else {
                continue
            }

            if let existingIndex = updated.firstIndex(where: {
                $0.id == selectedTool.id
                    || ($0.bundleIdentifier != nil && $0.bundleIdentifier == selectedTool.bundleIdentifier)
                    || URL(fileURLWithPath: $0.applicationPath).standardizedFileURL
                        == URL(fileURLWithPath: selectedTool.applicationPath).standardizedFileURL
            }) {
                updated[existingIndex] = selectedTool
            } else {
                updated.append(selectedTool)
            }
        }

        commit(updated)
    }

    func setEnabled(_ isEnabled: Bool, for id: String) {
        var updated = tools
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].isEnabled = isEnabled
        commit(updated)
    }

    func moveUp(_ id: String) {
        var updated = tools
        guard let index = updated.firstIndex(where: { $0.id == id }), index > 0 else { return }
        updated.swapAt(index, index - 1)
        commit(updated)
    }

    func remove(_ id: String) {
        commit(tools.filter { $0.id != id })
    }

    func restoreDefaults() {
        commit(ToolCatalog.defaultConfiguredTools())
    }

    func isAvailable(_ tool: ConfiguredTool) -> Bool {
        ToolCatalog.launchTool(for: tool).applicationURL != nil
    }

    func icon(for tool: ConfiguredTool) -> NSImage {
        let path = ToolCatalog.launchTool(for: tool).applicationURL?.path ?? tool.applicationPath
        return NSWorkspace.shared.icon(forFile: path)
    }

    private func commit(_ updated: [ConfiguredTool]) {
        if case .invalid = ToolConfigurationStore.loadResult() {
            errorMessage = "原工具配置无法读取，已阻止保存。请先重新连接配置。"
            return
        }
        do {
            try ToolConfigurationStore.save(updated)
            tools = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ToolSettingsPage: View {
    @ObservedObject var model: ToolSettingsModel
    @State private var confirmsRestore = false

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    SettingsPageHeader(
                        title: "打开工具",
                        subtitle: "选择显示在 Finder 右键菜单中的 App。打开目标会根据选中项和 App 类型自动判断。"
                    )
                    Spacer()
                    Label("更改已自动保存", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("右键菜单中的 App") {
                        VStack(spacing: 0) {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    if model.tools.isEmpty {
                                        ContentUnavailableView(
                                            "尚未添加 App",
                                            systemImage: "square.grid.2x2",
                                            description: Text("添加后会显示在 Finder 的“用工具打开”子菜单中。")
                                        )
                                        .frame(minHeight: 220)
                                    } else {
                                        ForEach(Array(model.tools.enumerated()), id: \.element.id) { index, tool in
                                            ToolConfigurationRow(
                                                model: model,
                                                tool: tool,
                                                canMoveUp: index > 0
                                            )
                                            if index < model.tools.count - 1 {
                                                Divider().padding(.leading, 58)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(maxHeight: .infinity)

                            Divider()
                            HStack(spacing: 9) {
                                Button("添加 App…", systemImage: "plus") {
                                    model.addApplications()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("恢复默认") {
                                    confirmsRestore = true
                                }

                                Spacer()
                                Text("智能打开，无需逐项设置目标")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    FinderMenuPreview(model: model)
                        .frame(width: 215)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: max(320, geometry.size.height - 140))
            }
            .padding(24)
        }
        .confirmationDialog("恢复默认工具？", isPresented: $confirmsRestore) {
            Button("恢复默认", role: .destructive) {
                model.restoreDefaults()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除自定义 App，并恢复当前检测到的默认工具和顺序。")
        }
    }
}

struct ToolConfigurationRow: View {
    @ObservedObject var model: ToolSettingsModel
    let tool: ConfiguredTool
    let canMoveUp: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.moveUp(tool.id)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .help("移到上一项")

            Image(nsImage: model.icon(for: tool))
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.body.weight(.medium))
                    if !model.isAvailable(tool) {
                        Text("App 不可用")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                Text(tool.applicationPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Toggle(
                "显示 \(tool.name)",
                isOn: Binding(
                    get: { tool.isEnabled },
                    set: { model.setEnabled($0, for: tool.id) }
                )
            )
            .labelsHidden()

            Button(role: .destructive) {
                model.remove(tool.id)
            } label: {
                Image(systemName: "minus.circle")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("移除 \(tool.name)")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
    }
}

struct FinderMenuPreview: View {
    @ObservedObject var model: ToolSettingsModel

    private var visibleTools: [ConfiguredTool] {
        model.tools.filter { $0.isEnabled && model.isAvailable($0) }
    }

    var body: some View {
        GroupBox("Finder 菜单预览") {
            VStack(alignment: .leading, spacing: 0) {
                PreviewMenuRow(title: "拷贝路径")
                PreviewMenuRow(title: "移动到…")
                PreviewMenuRow(title: "新建文件")
                Divider().padding(.vertical, 4)
                HStack {
                    Text("用工具打开")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .padding(.vertical, 5)
                Divider().padding(.vertical, 4)

                if visibleTools.isEmpty {
                    Text("暂无已启用的可用 App")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(visibleTools) { tool in
                        HStack(spacing: 7) {
                            Image(nsImage: model.icon(for: tool))
                                .resizable()
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(tool.name)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .padding(.vertical, 4)
                    }
                }

                Spacer(minLength: 8)
                Text("启用状态和顺序会在下次打开右键菜单时生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct PreviewMenuRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .padding(.vertical, 5)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OverviewSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(
                title: "概览",
                subtitle: "MacTools 为 Finder 增加常用文件操作，并保持菜单轻量。"
            )
            GroupBox("可用功能") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("拷贝一个或多个项目的完整路径", systemImage: "doc.on.doc")
                    Label("移动项目，支持同卷和跨卷校验", systemImage: "folder.badge.arrow.forward")
                    Label("新建文本、Markdown、JSON、Shell 与 Office 文件", systemImage: "doc.badge.plus")
                    Label("用已配置的 App 智能打开选中项", systemImage: "arrow.up.forward.app")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct NewFileSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(
                title: "新建文件",
                subtitle: "在 Finder 右键菜单中创建文件，文件名和类型会在创建前确认。"
            )
            GroupBox("支持的类型") {
                Text("文本、Markdown、JSON、Shell 脚本、Word、Excel、PowerPoint")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Text("此版本暂不提供额外选项。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}

struct ExtensionSettingsPage: View {
    let openExtensionSettings: () -> Void
    let restartFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(
                title: "Finder 扩展",
                subtitle: "管理扩展启用状态，并在菜单未刷新时重新启动 Finder。"
            )
            GroupBox("当前状态") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(FIFinderSyncController.isExtensionEnabled ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(FIFinderSyncController.isExtensionEnabled ? "扩展已启用" : "扩展未启用")
                    Spacer()
                }
                .padding(8)
            }
            HStack {
                Button("打开扩展设置", action: openExtensionSettings)
                    .buttonStyle(.borderedProminent)
                Button("重启 Finder", action: restartFinder)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct AboutSettingsPage: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Text("MacTools")
                .font(.title2.weight(.semibold))
            Text(versionText)
                .foregroundStyle(.secondary)
            Text("macOS 增强工具合集")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "版本 \(version)（\(build)）"
    }
}

struct StandaloneMenuSettingsPage: View {
    @ObservedObject var controller: StandaloneMenuController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(title: "独立菜单", subtitle: "在 iCloud 等目录中，通过修饰键加右键呼出文件操作菜单。使用时请保持 MacTools 运行。")
            GroupBox("呼出方式") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("启用独立菜单", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
                    Picker("快捷操作", selection: Binding(get: { controller.trigger }, set: { controller.setTrigger($0) })) {
                        ForEach(StandaloneMenuTrigger.allCases) { Text($0.title).tag($0) }
                    }
                    Text("适用于访达文件列表和图标区域。点击已选项目时保留多选；点击空白处时使用当前文件夹。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("运行状态") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(controller.status).fixedSize(horizontal: false, vertical: true)
                    Text("辅助功能权限用于识别鼠标下的文件和当前文件夹。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if !controller.trusted {
                            Button("请求辅助功能权限") { controller.requestPermission() }
                        }
                        Button("重新检查") { controller.refresh() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Spacer()
        }.padding(24)
    }
}
