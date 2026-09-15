import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsPage()
                .tabItem { Label("通用".localized, systemImage: "gearshape") }
            AgentSettingsPage()
                .tabItem { Label("Agent", systemImage: "puzzlepiece.extension") }
            WorkspaceSettingsPage()
                .tabItem { Label("工作区".localized, systemImage: "folder") }
            PermissionSettingsPage()
                .tabItem { Label("权限".localized, systemImage: "checkmark.shield") }
            MCPSettingsPage()
                .tabItem { Label("MCP", systemImage: "cable.connector") }
        }
        .frame(width: 560, height: 520)
        .liquidGlassWindow(appearance: model.colorScheme)
    }
}

struct GeneralSettingsPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        @Bindable var model = model
        Form {
            Section("外观".localized) {
                Picker("主题".localized, selection: $model.appearance) {
                    Text("跟随系统".localized).tag("system")
                    Text("浅色".localized).tag("light")
                    Text("深色".localized).tag("dark")
                }
                Toggle("在菜单栏显示图标".localized, isOn: $showMenuBarExtra)
            }

            Section("语言".localized) {
                Picker("界面语言".localized, selection: $model.appLanguage) {
                    Text("跟随系统".localized).tag(L10n.systemLanguage)
                    Text("简体中文".localized).tag("zh-Hans")
                    Text("English").tag("en")
                }
            }

            MarkdownDefaultSettingsSection()

            Section("新对话默认".localized) {
                Picker("Agent", selection: $model.selectedAgentId) {
                    ForEach(model.selectableAgents) { agent in
                        Text(agent.title).tag(agent.id)
                    }
                }
                Text("只影响下一条新对话，已打开的会话不会跟着变。".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 14) {
                    AppIconImage(size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aureways")
                            .font(.title3.weight(.semibold))
                        Text("版本 %@".localized(AppInfo.version))
                            .foregroundStyle(.secondary)
                        Text("macOS 原生 Agent 客户端".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } header: {
                Text("关于".localized)
            } footer: {
                Text("实现 Agent Client Protocol，在本机拉起已安装的命令行 Agent。".localized)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MarkdownDefaultSettingsSection: View {
    @State private var isDefault = false
    @State private var isUpdating = false
    @State private var statusMessage: String?

    var body: some View {
        Section {
            Button {
                Task { await registerAsDefault() }
            } label: {
                HStack {
                    Text(isDefault ? "已是默认 Markdown 打开方式".localized : "设为默认 Markdown 打开方式".localized)
                    Spacer(minLength: 8)
                    if isUpdating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isDefault || isUpdating)
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Markdown")
        } footer: {
            Text("双击 .md 文件，或在 Finder 里选「打开方式 → Aureways」。也可在此设为系统默认。".localized)
        }
        .onAppear { isDefault = MarkdownDefaultApp.isCurrent }
    }

    private func registerAsDefault() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await MarkdownDefaultApp.register()
            isDefault = MarkdownDefaultApp.isCurrent
            statusMessage = nil
        } catch {
            statusMessage = "无法设为默认打开方式：%@".localized(error.localizedDescription)
        }
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
                Text("内置".localized)
            } footer: {
                Text("登录和密钥由各 Agent 自己的命令行工具管理。点一行设为默认；开关控制是否出现在新建对话。已打开的会话不受影响。".localized)
            }

            if !customAgents.isEmpty {
                Section("自定义".localized) {
                    ForEach(customAgents) { agent in
                        AgentRow(agent: agent)
                    }
                }
            }

            Section {
                Button {
                    isShowingCustomSheet = true
                } label: {
                    Label("添加自定义 Agent".localized, systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshAvailability()
            Task {
                await model.quotaService.refreshAll(agents: model.agents)
            }
        }
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
                    Text(agent.builtIn ? "内置".localized : "自定义".localized)
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

            HarnessQuotaSummaryBadge(agentId: agent.id)

            if isDefault {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.moss)
                    .help("新建对话默认使用此 Agent".localized)
            }

            Toggle("", isOn: Binding(
                get: { model.isAgentEnabled(agent) },
                set: { model.setAgentEnabled(agent, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(isEnabled ? "停用后不会出现在新建对话的 Agent 选择里".localized : "重新启用此 Agent".localized)
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
        .help(isAvailable ? "已找到对应的命令行工具".localized : "未找到对应的命令行工具".localized)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("设为默认".localized) {
            model.selectedAgentId = agent.id
        }
        Button("复制启动命令".localized) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.launchLine, forType: .string)
        }
        if !agent.builtIn {
            Divider()
            Button("移除".localized, role: .destructive) {
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
                        Button("移除".localized, role: .destructive) {
                            model.removeWorkspace(workspace.path)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectWorkspace(workspace.path)
                    }
                }
                LabeledContent("新对话默认路径".localized, value: model.workspacePath)
                Button("添加工作区…".localized, action: model.addWorkspace)
            } header: {
                Text("已添加的工作区".localized)
            } footer: {
                Text("只显示你添加的项目。更改默认路径不会影响已打开的会话。".localized)
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
            Section("工具权限".localized) {
                Toggle("自动批准工具权限".localized, isOn: $model.autoApprove)
                Text("开启后，Agent 读写文件或执行命令时不再弹窗确认。部分 Agent 会把这项带到自己的会话里；其它选项可在会话信息中调整。".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct MCPSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false

    private var reportedServers: [McpServerConfig] {
        var seen = Set<String>()
        var servers: [McpServerConfig] = []
        for session in model.sessions where !session.isClosed {
            for server in session.reportedMcpServers where seen.insert(server.name).inserted {
                servers.append(server)
            }
        }
        return servers
    }

    private var agentCaps: McpCapabilities? {
        model.runtimes[model.selectedAgentId]?.capabilities.mcpCapabilities
    }

    var body: some View {
        Form {
            Section {
                if model.mcpServers.isEmpty {
                    Text("还没有配置 MCP 服务器。".localized)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.mcpServers) { server in
                        mcpRow(server)
                    }
                }
                Button("添加 MCP 服务器…".localized) {
                    isAdding = true
                }
            } header: {
                Text("发给 Agent 的服务器".localized)
            } footer: {
                Text("新建或恢复会话时写入 session/new 的 mcpServers。stdio 是规范基线；HTTP / SSE 仅当当前 Agent 声明 mcpCapabilities.http / sse 时才会发送。".localized)
            }

            if let caps = agentCaps {
                Section("当前 Agent 能力".localized) {
                    LabeledContent("HTTP") { Text(caps.http ? "支持".localized : "不支持".localized) }
                    LabeledContent("SSE") { Text(caps.sse ? "支持".localized : "不支持".localized) }
                }
            }

            if !reportedServers.isEmpty {
                Section {
                    ForEach(reportedServers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.summary.isEmpty ? server.transport.rawValue : server.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Agent 回传".localized)
                } footer: {
                    Text("部分 Agent 会在 session/new、session/load 或 session/list 里带回已连接的 MCP 服务器。这里只读展示。".localized)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $isAdding) {
            AddMCPServerSheet()
                .environment(model)
        }
    }

    @ViewBuilder
    private func mcpRow(_ server: McpServerConfig) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { enabled in
                    if let index = model.mcpServers.firstIndex(where: { $0.id == server.id }) {
                        model.mcpServers[index].enabled = enabled
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                    Text(server.transport.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(server.summary.isEmpty ? "未填写命令或地址".localized : server.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("移除".localized, role: .destructive) {
                model.mcpServers.removeAll { $0.id == server.id }
            }
        }
    }
}

private struct AddMCPServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transport: McpServerConfig.Transport = .stdio
    @State private var command = ""
    @State private var url = ""

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch transport {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .http, .sse:
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 MCP 服务器".localized)
                .font(.headline)
            Form {
                TextField("名称".localized, text: $name)
                Picker("传输".localized, selection: $transport) {
                    Text("stdio").tag(McpServerConfig.Transport.stdio)
                    Text("HTTP").tag(McpServerConfig.Transport.http)
                    Text("SSE").tag(McpServerConfig.Transport.sse)
                }
                if transport == .stdio {
                    TextField("启动命令".localized, text: $command)
                        .help("可带参数，例如 npx -y @modelcontextprotocol/server-filesystem /path".localized)
                } else {
                    TextField("URL", text: $url)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加".localized) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var commandName = ""
        var args: [String] = []
        if transport == .stdio {
            let parts = AgentCatalog.splitCommandLine(command.trimmingCharacters(in: .whitespacesAndNewlines))
            commandName = parts.first ?? ""
            args = Array(parts.dropFirst())
        }
        model.mcpServers.append(
            McpServerConfig(
                name: trimmedName,
                transport: transport,
                command: commandName,
                arguments: args,
                url: url.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        dismiss()
    }
}
