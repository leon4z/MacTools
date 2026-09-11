import AppKit
import SwiftUI

private enum MacToolsPage: String, CaseIterable, Identifiable {
    case finder = "访达右键增强", mouse = "鼠标工具", hyper = "Hyperkey", apps = "应用快捷键"
    var id: Self { self }
    var icon: String {
        switch self { case .finder: return "folder.badge.gearshape"; case .mouse: return "computermouse"; case .hyper: return "keyboard"; case .apps: return "command.square" }
    }
}

struct MacToolsRootView: View {
    @ObservedObject var model: ToolSettingsModel
    @ObservedObject var macTools: MacToolsModel
    @ObservedObject var standaloneMenu: StandaloneMenuController
    let openExtensionSettings: () -> Void
    let restartFinder: () -> Void
    @State private var page: MacToolsPage = .finder
    @State private var settings = false
    @State private var finderTab = 0
    @State private var mouseTab = 0
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityLabel("MacTools 图标")
                    Text("MacTools").font(.system(size: 24, weight: .bold))
                    Text("macOS 增强工具合集").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 26)
                ForEach(MacToolsPage.allCases) { item in
                    Button {
                        page = item; settings = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon).font(.title3).frame(width: 26)
                            Text(item.rawValue).font(.system(size: 14, weight: .medium))
                            Spacer()
                        }.padding(.horizontal, 14).padding(.vertical, 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .foregroundStyle(!settings && page == item ? Color.white : Color.primary)
                            .background(!settings && page == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(macTools.configuration.allEnabled ? Color.green : .orange).frame(width: 7, height: 7)
                    Text(macTools.configuration.allEnabled ? "增强已启用" : "全部增强已停用").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 14)
                Button { settings = true } label: {
                    Label("应用设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(settings ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(12).frame(width: 220).background(.primary.opacity(0.025))
            Divider()
            VStack(spacing: 0) {
                if settings {
                    AppSettingsPage(model: macTools)
                } else {
                    HStack {
                        Text(page.rawValue).font(.system(size: 22, weight: .semibold))
                        Spacer()
                        if page == .finder {
                            Picker("分类", selection: $finderTab) {
                                Text("文件操作").tag(0); Text("打开工具").tag(1); Text("独立菜单").tag(2); Text("扩展管理").tag(3)
                            }.pickerStyle(.segmented).frame(width: 365)
                        } else if page == .mouse {
                            Picker("分类", selection: $mouseTab) { Text("滚动").tag(0); Text("指针").tag(1) }.pickerStyle(.segmented).frame(width: 180)
                        }
                    }.padding(26)
                    Divider().opacity(0.45)
                    if page == .finder {
                        switch finderTab {
                        case 1: ToolSettingsPage(model: model)
                        case 2: ScrollView { StandaloneMenuSettingsPage(controller: standaloneMenu) }
                        case 3: ExtensionSettingsPage(openExtensionSettings: openExtensionSettings, restartFinder: restartFinder)
                        default: FinderActionsPage()
                        }
                    } else if page == .mouse {
                        MouseSettingsPage(model: macTools, runtime: macTools.input, tab: mouseTab)
                    } else if page == .apps {
                        AppShortcutSettingsPage(model: macTools.appShortcuts)
                    } else {
                        HyperSettingsPage(model: macTools, runtime: macTools.input)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .groupBoxStyle(MacToolsCardStyle())
        .onChange(of: macTools.configurationLoaded) { _, loaded in
            if loaded { model.reload() }
        }
        .alert("设置未保存", isPresented: Binding(get: { macTools.errorMessage != nil || model.errorMessage != nil }, set: { if !$0 { macTools.errorMessage = nil; model.errorMessage = nil } })) {
            Button("好") { macTools.errorMessage = nil; model.errorMessage = nil }
        } message: { Text(macTools.errorMessage ?? model.errorMessage ?? "未知错误") }
    }
}

struct MacToolsCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            configuration.label.font(.system(size: 14, weight: .semibold))
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FinderActionsPage: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GroupBox("文件操作") {
                    VStack(alignment: .leading, spacing: 22) {
                        action("拷贝路径", "一次复制一个或多个项目的完整路径", "doc.on.doc")
                        action("移动到…", "选择目标文件夹，支持同卷和跨卷校验", "folder")
                        action("新建文件", "文本、Markdown、JSON、Shell 和 Office 文件", "doc.badge.plus")
                        action("用工具打开", "使用你配置的应用打开所选文件或文件夹", "arrow.up.forward.app")
                    }
                }
                Text("在访达中右键选中项目即可使用。iCloud 等目录可通过“独立菜单”呼出。")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(26)
        }
    }
    private func action(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

private struct MouseSettingsPage: View {
    @ObservedObject var model: MacToolsModel
    @ObservedObject var runtime: InputRuntime
    let tab: Int
    private func binding<T>(_ key: WritableKeyPath<MousePreferences, T>) -> Binding<T> {
        Binding(get: { model.configuration.mouse[keyPath: key] }, set: { value in model.update { $0.mouse[keyPath: key] = value } })
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StatusCard(enabled: model.configuration.mouseActive, status: runtime.mouseStatus)
                if tab == 0 {
                    GroupBox("滚动体验") {
                        VStack(alignment: .leading, spacing: 20) {
                            Toggle("调整鼠标滚动", isOn: binding(\.scrolling))
                            Toggle("平滑滚动", isOn: binding(\.smooth)).disabled(!model.configuration.mouse.scrolling)
                            settingSlider("滚动速度", value: binding(\.scrollSpeed), range: 0.1...5, suffix: "倍")
                            settingSlider("滚动加速度", value: binding(\.scrollAcceleration), range: 0...2)
                            settingSlider("平滑时长", value: binding(\.smoothing), range: 0.03...0.5, suffix: "秒")
                                .disabled(!model.configuration.mouse.smooth)
                        }
                    }
                    GroupBox("滚动方向") {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("反转纵向滚动", isOn: binding(\.reverseVertical))
                            Toggle("反转横向滚动", isOn: binding(\.reverseHorizontal))
                            Text("相对于当前系统方向反转。仅处理普通鼠标离散滚轮；触控板和连续高精度滚动保持原样。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox("试试滚动") {
                        ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(1...24, id: \.self) { Text("\($0)  在这里滚动，感受速度与停止时的过渡。") } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
                    }
                } else {
                    GroupBox("指针控制") {
                        VStack(alignment: .leading, spacing: 20) {
                            Toggle("调整鼠标指针", isOn: binding(\.pointer))
                            settingSlider("移动速度", value: binding(\.pointerSpeed), range: 0.1...5, suffix: "倍")
                            Toggle("启用指针加速度", isOn: Binding(get: { model.configuration.mouse.pointerAcceleration >= 0 }, set: { value in model.update { $0.mouse.pointerAcceleration = value ? 0.5 : -1 } }))
                            if model.configuration.mouse.pointerAcceleration >= 0 {
                                settingSlider("指针加速度", value: binding(\.pointerAcceleration), range: 0...3)
                            }
                            Text("仅应用到鼠标设备。停用模块或退出应用时恢复原参数。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox("检测到的设备") {
                        Text(runtime.devices.isEmpty ? "未检测到鼠标服务" : runtime.devices.joined(separator: "\n"))
                            .font(.callout).textSelection(.enabled)
                    }
                }
                HStack { Spacer(); Button("恢复鼠标默认参数") { model.update { $0.mouse = MousePreferences() } } }
            }.padding(26)
        }
    }
}

private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "") -> some View {
    HStack(spacing: 16) {
        Text(title).frame(width: 100, alignment: .leading)
        Slider(value: value, in: range).accessibilityLabel(title)
        Text(String(format: "%.2f", value.wrappedValue) + suffix).font(.system(.callout, design: .monospaced)).frame(width: 68, alignment: .trailing)
    }
}

private struct StatusCard: View {
    let enabled: Bool
    let status: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: enabled ? "info.circle" : "pause.circle").foregroundStyle(.secondary)
            Text(status).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HyperSettingsPage: View {
    @ObservedObject var model: MacToolsModel
    @ObservedObject var runtime: InputRuntime
    private func binding<T>(_ key: WritableKeyPath<HyperPreferences, T>) -> Binding<T> {
        Binding(get: { model.configuration.hyper[keyPath: key] }, set: { value in model.update { $0.hyper[keyPath: key] = value } })
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StatusCard(enabled: model.configuration.hyperActive, status: runtime.hyperStatus)
                mappingCard("Hyper", key: \.hyper, symbols: model.configuration.hyper.includeShift ? "⌃ ⌥ ⌘ ⇧" : "⌃ ⌥ ⌘")
                mappingCard("Meh", key: \.meh, symbols: "⌃ ⌥ ⇧")
                GroupBox("同时作用于鼠标") {
                    HStack(spacing: 22) {
                        Toggle("点击", isOn: binding(\.clicks)); Toggle("拖动", isOn: binding(\.drags))
                        Toggle("移动", isOn: binding(\.moves)); Toggle("滚动", isOn: binding(\.scroll))
                    }
                    Text("键盘组合键始终生效。使用过组合操作后，松开触发键不再执行单击映射。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(26)
        }.onDisappear { model.recording = false }
    }
    private func mappingCard(_ title: String, key: WritableKeyPath<HyperPreferences, ModifierMapping>, symbols: String) -> some View {
        let mapping = Binding<ModifierMapping>(get: { model.configuration.hyper[keyPath: key] }, set: { value in model.update { $0.hyper[keyPath: key] = value } })
        return GroupBox(title + "   " + symbols) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Toggle("启用 \(title) 映射", isOn: mapping.enabled)
                    Spacer()
                    Picker("触发键", selection: mapping.trigger) {
                        ForEach(ModifierTrigger.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 230)
                }
                if title == "Hyper" { Toggle("包含 Shift", isOn: binding(\.includeShift)) }
                HStack {
                    Picker("单击映射", selection: Binding(get: { ShortcutPreset.selection(for: mapping.wrappedValue.tap) }, set: { id in
                        if let preset = ShortcutPreset.all.first(where: { $0.id == id }) { model.recording = false; mapping.wrappedValue.tap = preset.shortcut }
                    })) {
                        Text("自定义组合键").tag(-1)
                        ForEach(ShortcutPreset.all) { Text($0.title).tag($0.id) }
                    }.frame(width: 260)
                    Spacer()
                }
                HStack {
                    Text("组合键录制").frame(width: 86, alignment: .leading)
                    ShortcutRecorder(shortcut: mapping.tap, recording: $model.recording).frame(height: 30)
                    Button("清除") { mapping.wrappedValue.tap = TapShortcut() }
                }
                Text("辅助键可从下拉栏选择；组合键点击录制框录入。单击辅助键只发送一次按下和松开，不会持续按住。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppSettingsPage: View {
    @ObservedObject var model: MacToolsModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("应用设置").font(.system(size: 24, weight: .semibold))
                ConfigurationAccessCard(model: model, shortcuts: model.appShortcuts)
                GroupBox("增强开关") {
                    VStack(alignment: .leading, spacing: 20) {
                        Toggle("启用全部增强", isOn: bind(\.allEnabled)).toggleStyle(.switch)
                        Text("关闭后停用所有模块，保留你的配置。重新开启后恢复各模块的启用状态。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("访达右键增强", isOn: bind(\.finderEnabled))
                        Toggle("鼠标工具", isOn: bind(\.mouseEnabled))
                        Toggle("Hyperkey / Meh", isOn: bind(\.hyperEnabled))
                        AppShortcutModuleToggle(model: model.appShortcuts)
                    }
                }
                PermissionCard(runtime: model.input, refresh: { model.refresh() })
                AppUpdateSettings(model: model.updates)
                GroupBox("关于 MacTools") {
                    Text("macOS 增强工具合集，让日常操作更顺手。")
                    Text("访达、鼠标、Hyper／Meh、应用快捷键，按需开启。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(versionText).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(26)
        }
    }
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "版本 \(version)（\(build)）"
    }
    private func bind(_ key: WritableKeyPath<MacToolsConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }
}

private struct ConfigurationAccessCard: View {
    @ObservedObject var model: MacToolsModel
    @ObservedObject var shortcuts: AppShortcutModel
    var body: some View {
        if !model.configurationLoaded || !shortcuts.configurationLoaded {
            GroupBox("原有配置需要重新连接") {
                Text("macOS 暂时不允许读取原配置。读取成功前不会保存更改，也不会覆盖原来的设置。")
                    .font(.callout)
                Button("重新连接配置…") { model.reconnectConfiguration() }
            }
        }
    }
}

private struct PermissionCard: View {
    @ObservedObject var runtime: InputRuntime
    let refresh: () -> Void
    var body: some View {
        GroupBox("权限与运行状态") {
            VStack(alignment: .leading, spacing: 14) {
                Label(runtime.trusted ? "辅助功能已授权" : "需要辅助功能授权", systemImage: runtime.trusted ? "checkmark.circle" : "exclamationmark.circle")
                Text("授权后点击重新检查。如果系统开关已开启但这里仍未授权，请从权限列表移除旧条目，再添加当前 MacTools。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("打开权限设置") { runtime.openPermissionSettings() }
                    Button("重新检查", action: refresh)
                }
            }
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: TapShortcut
    @Binding var recording: Bool
    func makeNSView(context: Context) -> RecorderField { RecorderField() }
    func updateNSView(_ view: RecorderField, context: Context) {
        view.label = shortcut.label
        view.onFocus = { recording = $0 }
        view.onRecord = { shortcut = $0; recording = false }
        if !recording && view.isRecording { view.window?.makeFirstResponder(nil) }
        view.needsDisplay = true
    }
}

final class RecorderField: NSView {
    var label = "不执行操作"
    var isRecording = false
    var onFocus: ((Bool) -> Void)?
    var onRecord: ((TapShortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool { isRecording = true; onFocus?(true); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { isRecording = false; onFocus?(false); needsDisplay = true; return true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }; keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.command) { prefix += "⌘" }
        if flags.contains(.shift) { prefix += "⇧" }
        let names: [UInt16: String] = [53:"Esc", 36:"Return", 48:"Tab", 49:"Space", 51:"Delete", 123:"←", 124:"→", 125:"↓", 126:"↑"]
        let name = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        onRecord?(TapShortcut(keyCode: event.keyCode, label: prefix + name, modifiers: UInt64(flags.rawValue)))
        window?.makeFirstResponder(nil)
    }
    override func draw(_ dirtyRect: NSRect) {
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let text = isRecording ? "请按下按键或组合键…" : (label + "  · 点击录制")
        (text as NSString).draw(at: NSPoint(x: 10, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
    }
}
