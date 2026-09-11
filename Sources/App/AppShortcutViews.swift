import SwiftUI
import AppKit

struct AppShortcutSettingsPage: View {
    @ObservedObject var model: AppShortcutModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("快捷切换应用") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用应用快捷键", isOn: Binding(get: { model.configuration.enabled }, set: { value in model.update { $0.enabled = value } }))
                            .toggleStyle(.switch)
                        Text("按下快捷键打开或切换到目标应用；目标应用已在前台时，再按一次将其隐藏，回到之前的应用。")
                            .foregroundStyle(.secondary)
                        Text(model.status).font(.callout)
                        HStack {
                            Button("添加应用…", action: model.addApplication)
                            Spacer()
                            Text("支持 ⌘ / ⌥ / ⌃ 组合及 Hyper／Meh").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.configuration.apps.isEmpty {
                    ContentUnavailableView("还没有应用快捷键", systemImage: "command.square", description: Text("添加常用应用，为每个应用设置一个快捷键。"))
                }
                ForEach(model.configuration.apps) { app in
                    AppShortcutRow(model: model, app: app)
                }
                Text("录制期间会暂停本模块的快捷键，Hyper／Meh 仍可用。若提示占用，请在 Thor 或其他应用中停用对应快捷键。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
        .onDisappear { model.recording = false }
        .alert("应用快捷键未保存", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
        Toggle("应用快捷键", isOn: Binding(get: { model.configuration.enabled }, set: { value in model.update { $0.enabled = value } }))
            .alert("应用快捷键未保存", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("好") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}
