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
                    ForEach(model.selectableAgents) { agent in
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

    private var builtinAgents: [AgentProfile] {
        sortDefaultFirst(model.agents.filter(\.builtIn))
    }

    private var customAgents: [AgentProfile] {
        sortDefaultFirst(model.agents.filter { !$0.builtIn })
    }

    private func sortDefaultFirst(_ list: [AgentProfile]) -> [AgentProfile] {
        list.enumerated()
            .sorted { lhs, rhs in
                let lhsDefault = lhs.element.id == model.selectedAgentId
                let rhsDefault = rhs.element.id == model.selectedAgentId
                if lhsDefault != rhsDefault { return lhsDefault }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var body: some View {
        Form {
            Section {
                ForEach(builtinAgents) { agent in
                    AgentRow(agent: agent)
                }
            } header: {
                Text("内置")
            } footer: {
                Text("登录、API Key 和 CLI 全局配置由各 harness 自己维护。点击行设为默认，开关控制是否出现在新建对话；已打开的会话不受影响。")
            }

            if !customAgents.isEmpty {
                Section("自定义") {
                    ForEach(customAgents) { agent in
                        AgentRow(agent: agent)
                    }
                }
            }

            Section {
                Button {
                    isShowingCustomSheet = true
                } label: {
                    Label("添加自定义 Agent", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAvailability() }
        .sheet(isPresented: $isShowingCustomSheet) {
            CustomAgentSheet()
                .environment(model)
        }
    }
}

private struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentProfile

    private var isDefault: Bool { model.selectedAgentId == agent.id }
    private var isEnabled: Bool { model.isAgentEnabled(agent) }
    private var isAvailable: Bool { model.availability[agent.id] == true }

    var body: some View {
        HStack(spacing: 10) {
            monogram

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(agent.builtIn ? "内置" : "自定义")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.badgeBg, in: Capsule())
                }
                Text(agent.launchLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(agent.notes)
            }

            Spacer()

            if isDefault {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.moss)
                    .help("新建对话默认使用此 harness")
            }

            Toggle("", isOn: Binding(
                get: { model.isAgentEnabled(agent) },
                set: { model.setAgentEnabled(agent, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(isEnabled ? "停用后不会出现在新建对话的 harness 选择里" : "点击重新启用该 harness")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.55)
        .onTapGesture {
            model.selectedAgentId = agent.id
        }
        .contextMenu { contextMenu }
    }

    private var monogram: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Palette.badgeBg)
                .frame(width: 26, height: 26)
                .overlay {
                    Text(String(agent.title.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.accent)
                }
            Circle()
                .fill(isAvailable ? Palette.moss : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
        }
        .help(isAvailable ? "CLI 可用" : "未检测到 CLI；重开设置页或点通用页的可用性会自动重测")
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("设为默认") {
            model.selectedAgentId = agent.id
        }
        Button("复制启动命令") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.launchLine, forType: .string)
        }
        if !agent.builtIn {
            Divider()
            Button("移除", role: .destructive) {
                model.removeAgent(agent)
            }
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
