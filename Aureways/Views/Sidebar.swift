import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var isSearching = false
    @State private var showAgentHub = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // 1. Top Header (Brand Dropdown & Action Icons)
            SidebarHeader(showAgentHub: $showAgentHub, isSearching: $isSearching)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if isSearching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("搜索会话...", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !model.searchQuery.isEmpty {
                        Button {
                            model.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            // 2. Scrollable Navigation, Projects & Sessions
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Quick Action Entries
                    VStack(spacing: 2) {
                        SidebarNavRow(
                            icon: "square.and.pencil",
                            title: "新对话",
                            trailingIcon: "plus.circle",
                            isSelected: model.selectedSessionID == nil
                        ) {
                            model.selectedSessionID = nil
                        }

                        SidebarNavRow(
                            icon: "puzzlepiece.extension",
                            title: "Agent 与插件",
                            badge: "\(model.agents.filter { model.availability[$0.id] == true }.count) 可用",
                            isSelected: false
                        ) {
                            showAgentHub = true
                        }

                        SidebarNavRow(
                            icon: "folder",
                            title: "工作区目录",
                            badge: model.workspaceBranch ?? model.currentWorkspaceName,
                            isSelected: false
                        ) {
                            model.openWorkspaceInFinder()
                        }
                    }

                    // Projects Section (Grouped by Workspace)
                    if !model.groupedSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("项目")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)

                            ForEach(model.groupedSessions, id: \.workspacePath) { group in
                                ProjectGroupView(
                                    name: group.workspaceName,
                                    path: group.workspacePath,
                                    sessions: group.sessions
                                )
                            }
                        }
                    }

                    // Recent Section
                    if !model.filteredSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("最近")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)

                            ForEach(Array(model.filteredSessions.prefix(6))) { session in
                                SessionNavItem(session: session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            Divider().overlay(Palette.border)

            // 3. User Profile Footer
            UserProfileFooter(showAgentHub: $showAgentHub)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background {
            if model.useLiquidGlass {
                VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
            } else {
                Palette.panel
            }
        }
        .sheet(isPresented: $showAgentHub) {
            AgentHubSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.isShowingCustomSheet) {
            CustomAgentSheet()
                .environment(model)
        }
    }
}

// MARK: - Sidebar Header

struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var showAgentHub: Bool
    @Binding var isSearching: Bool

    var body: some View {
        HStack {
            Menu {
                Text("Aureways v0.1.0 (ACP v1)")
                Divider()
                Button("切换工作区...") { model.pickWorkspace() }
                Button("在 Finder 中打开工作区") { model.openWorkspaceInFinder() }
                Divider()
                Button("Agent & 插件管理...") { showAgentHub = true }
                Button("添加自定义 Agent...") { model.isShowingCustomSheet = true }
                Divider()
                Button("刷新 Agent 可用性") { model.refreshAvailability() }
            } label: {
                HStack(spacing: 5) {
                    Text("Aureways")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSearching.toggle()
                }
            } label: {
                Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(isSearching ? Palette.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("搜索对话")

            Button {
                model.selectedSessionID = nil
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("新建对话 (⌘N)")
        }
    }
}

// MARK: - Navigation Row

struct SidebarNavRow: View {
    let icon: String
    let title: String
    var badge: String? = nil
    var trailingIcon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Palette.accent : (isHovered ? .primary : .secondary))

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Palette.badgeBg, in: Capsule())
                }

                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Palette.card : (isHovered ? Palette.card.opacity(0.5) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Project Group

struct ProjectGroupView: View {
    let name: String
    let path: String
    let sessions: [ChatSession]
    @State private var isExpanded = true
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Folder header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent)
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Session List under this project
            if isExpanded {
                let displayCount = showAll ? sessions.count : min(sessions.count, 5)
                ForEach(Array(sessions.prefix(displayCount))) { session in
                    SessionNavItem(session: session)
                }

                if sessions.count > 5 {
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Text(showAll ? "收起" : "展开显示 (\(sessions.count - 5) 条更多)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Session Nav Item

struct SessionNavItem: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    @State private var isHovered = false

    var isSelected: Bool {
        model.selectedSessionID == session.id
    }

    var shortcutBadge: String? {
        model.sessionShortcut(for: session)
    }

    var body: some View {
        Button {
            model.selectedSessionID = session.id
        } label: {
            HStack(spacing: 8) {
                if session.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(session.phase.isReady ? Palette.moss : (caseFailed(session.phase) ? Color.red : Palette.gold))
                        .frame(width: 6, height: 6)
                }

                Text(session.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(1)

                Spacer()

                if let shortcut = shortcutBadge {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? Palette.accent : Color.secondary.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Palette.card : (isHovered ? Palette.card.opacity(0.6) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("关闭会话", role: .destructive) {
                model.close(session)
            }
            Button("复制标题") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.title, forType: .string)
            }
            Divider()
            Button("在 Finder 中查看工作区") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
            }
        }
    }

    private func caseFailed(_ phase: SessionPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}

// MARK: - User Profile Footer

struct UserProfileFooter: View {
    @Environment(AppModel.self) private var model
    @Binding var showAgentHub: Bool

    var body: some View {
        HStack(spacing: 9) {
            // User Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.8), Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Text(String(model.userName.prefix(2)).lowercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.userName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text("ACP 客户端已就绪")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("偏好设置...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
                Divider()
                Button("Agent & 插件管理...") { showAgentHub = true }
                Button("添加自定义 Agent...") { model.isShowingCustomSheet = true }
                Divider()
                Button("切换工作区...") { model.pickWorkspace() }
                Button("刷新 Agent 可用性") { model.refreshAvailability() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置与偏好 (⌘,)")
        }
    }
}

// MARK: - Agent & Plugin Hub Sheet

struct AgentHubSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent 与插件中心")
                        .font(.title3.weight(.semibold))
                    Text("已注册的本地 ACP Harness 与扩展")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.agents) { agent in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(model.availability[agent.id] == true ? Palette.moss : Color.secondary.opacity(0.35))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
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
                                }
                                Text(agent.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(agent.notes)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Button("启动新对话") {
                                model.startSession(agent)
                                dismiss()
                            }
                            .controlSize(.small)
                            .disabled(model.availability[agent.id] != true)

                            if !agent.builtIn {
                                Button(role: .destructive) {
                                    model.removeAgent(agent)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Button {
                    model.isShowingCustomSheet = true
                } label: {
                    Label("添加自定义 Agent...", systemImage: "plus")
                }
                Spacer()
                Button("刷新可用性") {
                    model.refreshAvailability()
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Custom Agent Sheet

struct CustomAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义 ACP Agent")
                .font(.title3.weight(.semibold))
            Text("支持任意遵循 stdio ACP 协议的 CLI 工具。例如：grok agent stdio")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("名称 (如: My Custom Agent)", text: $model.customTitle)
                .textFieldStyle(.roundedBorder)

            TextField("启动命令 (如: /opt/homebrew/bin/opencode acp)", text: $model.customCommand)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    model.addCustomAgent()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

