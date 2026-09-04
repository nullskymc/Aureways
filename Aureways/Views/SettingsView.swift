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
            }

            Section("新对话默认") {
                Picker("Agent", selection: $model.selectedAgentId) {
                    ForEach(model.selectableAgents) { agent in
                        Text(agent.title).tag(agent.id)
                    }
                }
                Text("只影响下一条新对话，已打开的会话不会跟着变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("客户端", value: "Aureways \(AppInfo.version)")
                LabeledContent("协议", value: "Agent Client Protocol")
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
                Text("登录和密钥由各 Agent 自己的命令行工具管理。点一行设为默认；开关控制是否出现在新建对话。已打开的会话不受影响。")
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
                    .help("新建对话默认使用此 Agent")
            }

            Toggle("", isOn: Binding(
                get: { model.isAgentEnabled(agent) },
                set: { model.setAgentEnabled(agent, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(isEnabled ? "停用后不会出现在新建对话的 Agent 选择里" : "重新启用此 Agent")
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
        .help(isAvailable ? "已找到对应的命令行工具" : "未找到对应的命令行工具")
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
                Text("只显示你添加的项目。更改默认路径不会影响已打开的会话。")
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
            Section("工具权限") {
                Toggle("自动批准工具权限", isOn: $model.autoApprove)
                Text("开启后，Agent 读写文件或执行命令时不再弹窗确认。部分 Agent 会把这项带到自己的会话里；其它选项可在会话信息中调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
