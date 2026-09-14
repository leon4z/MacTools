import SwiftUI
import AppKit

struct AppShortcutSettingsPage: View {
    @ObservedObject var model: AppShortcutModel
    let tab: Int
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(tab == 0 ? "快捷切换应用" : "快捷执行系统操作") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用快捷键", isOn: Binding(get: { model.configuration.enabled }, set: { value in model.update { $0.enabled = value } }))
                            .toggleStyle(.switch)
                        Text(tab == 0 ? "按下快捷键打开或切换到目标应用；目标应用已在前台时，再按一次将其隐藏，回到之前的应用。" : "选择系统操作，再录制组合键。例如将 Meh + L（⌃⌥⇧L）设为锁定屏幕。")
                            .foregroundStyle(.secondary)
                        HStack {
                            if tab == 0 {
                                Button("添加应用…", action: model.addApplication)
                            } else {
                                Menu("添加系统操作") {
                                    ForEach(SystemShortcutCategory.allCases) { category in
                                        Menu(category.rawValue) {
                                            ForEach(SystemShortcutAction.allCases.filter { $0.category == category }) { action in
                                                Button(action.title) { model.addSystemAction(action) }
                                            }
                                        }
                                    }
                                }.fixedSize()
                            }
                            Spacer()
                            Text("支持 ⌘ / ⌥ / ⌃ 组合及 Hyper／Meh").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if tab == 0 {
                    if model.configuration.apps.isEmpty {
                        ContentUnavailableView("还没有应用快捷键", systemImage: "command.square", description: Text("添加常用应用，为每个应用设置一个快捷键。"))
                    }
                    ForEach(model.configuration.apps) { app in AppShortcutRow(model: model, app: app) }
                } else {
                    if model.configuration.systemActions.isEmpty {
                        ContentUnavailableView("还没有系统操作快捷键", systemImage: "keyboard", description: Text("添加锁屏、截图、媒体控制等操作，再设置你习惯的组合键。"))
                    }
                    ForEach(model.configuration.systemActions) { item in SystemShortcutRow(model: model, item: item) }
                }
                Text("录制期间会暂停本模块的快捷键，Hyper／Meh 仍可用。若提示占用，请在 Thor 或其他应用中停用对应快捷键。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
        .onDisappear { model.recording = false }
        .onChange(of: tab) { _, _ in model.recording = false }
        .alert("快捷键未保存", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct SystemShortcutRow: View {
    @ObservedObject var model: AppShortcutModel
    let item: SystemShortcut
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: item.action.icon).font(.title).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.action.title).font(.headline)
                        Text(item.action.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用 \(item.action.title)", isOn: Binding(get: { item.enabled }, set: { value in model.updateSystemAction(item.id) { $0.enabled = value } })).labelsHidden()
                    Button(role: .destructive) { model.recording = false; model.update { $0.systemActions.removeAll { $0.id == item.id } } } label: {
                        Image(systemName: "minus.circle").frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("移除 \(item.action.title)")
                }
                HStack {
                    Text("快捷键").frame(width: 60, alignment: .leading)
                    ShortcutRecorder(shortcut: Binding(get: { item.shortcut }, set: { value in model.updateSystemAction(item.id) { $0.shortcut = value } }), recording: $model.recording).frame(height: 30)
                    Button("清除") { model.updateSystemAction(item.id) { $0.shortcut = TapShortcut() } }
                }
                if item.action == .sendShortcut {
                    HStack {
                        Text("发送按键").frame(width: 60, alignment: .leading)
                        ShortcutRecorder(shortcut: Binding(get: { item.targetShortcut ?? TapShortcut() }, set: { value in model.updateSystemAction(item.id) { $0.targetShortcut = value } }), recording: $model.recording).frame(height: 30)
                        Button("清除") { model.updateSystemAction(item.id) { $0.targetShortcut = nil } }
                    }
                }
                if let issue = model.issues[item.id] { Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

private struct AppShortcutRow: View {
    @ObservedObject var model: AppShortcutModel
    let app: AppShortcut
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.applicationPath)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline)
                        Text(app.applicationPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("启用 \(app.name)", isOn: Binding(get: { app.enabled }, set: { value in model.updateApp(app.id) { $0.enabled = value } })).labelsHidden()
                    Button { model.activate(app) } label: {
                        Image(systemName: "arrow.up.forward.app").frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("打开 \(app.name)")
                    Button(role: .destructive) { model.recording = false; model.update { $0.apps.removeAll { $0.id == app.id } } } label: {
                        Image(systemName: "minus.circle").frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("移除 \(app.name)")
                }
                HStack {
                    Text("快捷键").frame(width: 60, alignment: .leading)
                    ShortcutRecorder(shortcut: Binding(get: { app.shortcut }, set: { value in model.updateApp(app.id) { $0.shortcut = value } }), recording: $model.recording).frame(height: 30)
                    Button("清除") { model.updateApp(app.id) { $0.shortcut = TapShortcut() } }
                }
                if let issue = model.issues[app.id] { Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct AppShortcutModuleToggle: View {
    @ObservedObject var model: AppShortcutModel
    var body: some View {
        Toggle("快捷键", isOn: Binding(get: { model.configuration.enabled }, set: { value in model.update { $0.enabled = value } }))
            .alert("快捷键未保存", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("好") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}
