import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsPage()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AgentSettingsPage()
                .tabItem { Label("Agent", systemImage: "puzzlepiece.extension") }
            WorkspaceSettingsPage()
                .tabItem { Label("工作区", systemImage: "folder") }
            PermissionSettingsPage()
                .tabItem { Label("权限", systemImage: "checkmark.shield") }
        }
        .frame(width: 560, height: 520)
        .liquidGlassWindow(appearance: model.colorScheme)
    }
}

struct GeneralSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("外观") {
                Picker("主题", selection: $model.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Text("窗口与控件材质跟随系统的 Liquid Glass 外观。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("新对话默认") {
                Picker("Harness", selection: $model.selectedAgentId) {
                    ForEach(model.agents) { agent in
                        Text(agent.title).tag(agent.id)
                    }
                }
                Text("只作用于空白画布上的下一条新对话，不会改已打开会话绑定的 Agent。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("客户端", value: "Aureways \(AppInfo.version)")
                LabeledContent("协议", value: "ACP v1 · stdio JSON-RPC")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AgentSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingCustomSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登录、API Key 和 CLI 全局配置由各 harness 自己维护。这里只登记本机如何启动它们。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.agents) { agent in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(model.availability[agent.id] == true ? Palette.moss : Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(agent.title)
                                    .font(.system(size: 13, weight: .medium))
                                if agent.builtIn {
                                    Text("内置")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Palette.accent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Palette.badgeBg, in: Capsule())
                                }
                                if model.selectedAgentId == agent.id {
                                    Text("默认")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(agent.launchLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(agent.notes)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("设为默认") {
                                model.selectedAgentId = agent.id
                            }
                            .controlSize(.small)
                            .disabled(model.selectedAgentId == agent.id)
                            if !agent.builtIn {
                                Button("移除", role: .destructive) {
                                    model.removeAgent(agent)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)

            HStack {
                Button {
                    isShowingCustomSheet = true
                } label: {
                    Label("添加自定义 Agent", systemImage: "plus")
                }
                Spacer()
                Button("刷新可用性", action: model.refreshAvailability)
            }
        }
        .padding(16)
        .sheet(isPresented: $isShowingCustomSheet) {
            CustomAgentSheet()
                .environment(model)
        }
    }
}

struct WorkspaceSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.workspaces) { workspace in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name)
                            Text(workspace.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if workspace.path == model.workspacePath {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.moss)
                        }
                        Button("移除", role: .destructive) {
                            model.removeWorkspace(workspace.path)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectWorkspace(workspace.path)
                    }
                }
                LabeledContent("新对话默认路径", value: model.workspacePath)
                Button("添加工作区…", action: model.addWorkspace)
            } header: {
                Text("已添加的工作区")
            } footer: {
                Text("工作区列表由 Aureways 维护，只包含你添加的项目目录，不含用户主目录。已打开会话的 cwd 不会因为改默认路径而更换。")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PermissionSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Client 权限策略") {
                Toggle("自动批准工具权限", isOn: $model.autoApprove)
                Text("这是 Aureways 如何回答 `session/request_permission`：开启后选第一个允许项。不是 Grok/Codex 自己的配置文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("透传到 harness") {
                Text("各 harness 自己决定如何把自动批准透传过去。Grok Build 会加 `--always-approve` 和 `_meta.yoloMode`；其它家若用 ACP `configOptions` 暴露审批/沙箱，在已打开的会话里改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
