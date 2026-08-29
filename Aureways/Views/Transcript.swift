import SwiftUI

// MARK: - Empty Workspace Landing View (Codex Style)

struct EmptyWorkspaceLanding: View {
    @Environment(AppModel.self) private var model
    @State private var isHoveringWorkspace = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    if model.useLiquidGlass {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Palette.accent.opacity(0.30),
                                        Palette.sky.opacity(0.18),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: 160
                                )
                            )
                            .frame(width: 320, height: 320)
                            .blur(radius: 45)
                    }

                    Image(systemName: "cloud")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Palette.accent.opacity(0.85))

                    Image(systemName: "terminal")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .offset(y: 4)
                }

                HStack(spacing: 4) {
                    Text("你想让我们在")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.primary)

                    Button(action: model.pickWorkspace) {
                        Text(model.currentWorkspaceName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .underline(true, color: Palette.accent.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringWorkspace = $0 }
                    .help("点击切换工作区 (当前: \(model.workspacePath))")

                    Text("中构建什么？")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .multilineTextAlignment(.center)
            }

            Spacer()

            ComposerCard(session: nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session Status Bar

struct SessionStatusBar: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession

    var body: some View {
        HStack(spacing: 8) {
            statusDot

            HStack(spacing: 5) {
                Text(session.agent.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if !session.agentInfo.isEmpty {
                    Text("· \(session.agentInfo)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if case .failed = session.phase {
                Button {
                    model.retry(session)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(Palette.panel.opacity(0.45))
    }

    @ViewBuilder
    private var statusDot: some View {
        switch session.phase {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .ready:
            Circle()
                .fill(Palette.moss)
                .frame(width: 8, height: 8)
        case .failed:
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 8, height: 8)
        }
    }

    private var statusText: String {
        switch session.phase {
        case .connecting:
            return "正在启动 \(session.agent.launchLine)..."
        case .ready:
            return "工作区: \(session.cwd)"
        case .failed(let message):
            return "错误: \(message)"
        }
    }
}

// MARK: - Transcript View

struct TranscriptView: View {
    let session: ChatSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(session.items) { item in
                            TranscriptRow(item: item)
                                .id(item.id)
                        }

                        if session.isStreaming {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Agent 正在处理中...")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Palette.panel, in: Capsule())
                            .id("streaming")
                        }
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.transcriptRevision) {
                scrollToLatest(proxy)
            }
            .onChange(of: session.isStreaming) {
                scrollToLatest(proxy)
            }
        }
        .background(Palette.ink)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if session.isStreaming {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let id = session.items.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

// MARK: - Transcript Row

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item {
        case .user(_, let text):
            userBubble(text: text)
        case .agent(_, let text):
            agentBubble(markdown: text)
        case .thought(_, let text):
            thoughtBubble(text: text)
        case .tool(_, let call):
            ToolCard(call: call)
        case .plan(_, let entries):
            PlanCard(entries: entries)
        case .status(_, let text):
            statusNotice(text: text)
        }
    }

    @ViewBuilder
    private func userBubble(text: String) -> some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Palette.cardHover,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Palette.border.opacity(0.8), lineWidth: 0.8)
                    )
            }
        }
    }

    @ViewBuilder
    private func agentBubble(markdown: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.moss.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.moss)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                if let attributed = try? AttributedString(
                    markdown: markdown,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    Text(markdown)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func thoughtBubble(text: String) -> some View {
        DisclosureGroup {
            Text(text)
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Palette.accent.opacity(0.4))
                        .frame(width: 2)
                }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("思考过程 (Thinking)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func statusNotice(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 40)
    }
}

// MARK: - Tool Card

struct ToolCard: View {
    let call: ToolCallView
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.sky)

                    Text(call.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(call.status.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let rawInput = call.rawInput, let inputStr = try? String(data: rawInput.encode(), encoding: .utf8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("输入参数：")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(inputStr)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                if !call.contentText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("输出结果：")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(call.contentText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border, lineWidth: 1))
    }

    private var icon: String {
        switch call.kind {
        case "read": return "doc.text"
        case "edit", "delete", "move": return "pencil"
        case "execute": return "terminal"
        case "search": return "magnifyingglass"
        case "fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch call.status.lowercased() {
        case "completed", "success": return Palette.moss
        case "failed", "error": return .red
        case "in_progress", "running": return Palette.sky
        default: return Palette.gold
        }
    }
}

// MARK: - Plan Card

struct PlanCard: View {
    let entries: [PlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 12))
                Text("执行计划 (Plan)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)

            ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: entry.status))
                        .font(.system(size: 12))
                        .foregroundStyle(entry.status == "completed" ? Palette.moss : Palette.accent)
                        .padding(.top, 2)

                    Text(entry.content)
                        .font(.system(size: 12.5))
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border, lineWidth: 1))
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }
}

// MARK: - Inspector Pane View (Right Panel)

struct InspectorPaneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Header Tab Selector
            HStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        model.selectedInspectorTab = tab
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 11.5, weight: model.selectedInspectorTab == tab ? .semibold : .regular))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(model.selectedInspectorTab == tab ? .primary : .secondary)
                        .background(
                            model.selectedInspectorTab == tab ? Palette.card : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8)
            .background(Palette.panel)

            Divider().overlay(Palette.border)

            Group {
                switch model.selectedInspectorTab {
                case .review:
                    ReviewInspectorTab(session: model.selectedSession)
                case .terminal:
                    TerminalInspectorTab(session: model.selectedSession)
                case .logs:
                    LogsInspectorTab(session: model.selectedSession)
                case .files:
                    FilesInspectorTab()
                case .info:
                    InfoInspectorTab(session: model.selectedSession)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if model.useLiquidGlass {
                VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
            } else {
                Palette.panel
            }
        }
    }
}

// MARK: - Inspector Tabs

struct ReviewInspectorTab: View {
    let session: ChatSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件读写与变更审查")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            if let ops = session?.fileOps, !ops.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(ops) { op in
                            HStack(spacing: 8) {
                                Text(op.type.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(op.type == "write" ? Palette.moss : Palette.sky)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(op.fileName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(op.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("当前会话暂无文件读写记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TerminalInspectorTab: View {
    let session: ChatSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动终端")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("终端由 Agent 按需通过 ACP 动态启动与执行")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LogsInspectorTab: View {
    let session: ChatSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent stderr 日志")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Spacer()
                if let count = session?.logs.count, count > 0 {
                    Text("\(count) 条")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if let logs = session?.logs, !logs.isEmpty {
                ScrollView {
                    Text(logs.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(Palette.ink)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("暂无 stderr 日志输出")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct WorkspaceEntry: Identifiable {
    let id: String
    let name: String
    let isDirectory: Bool
}

struct FilesInspectorTab: View {
    @Environment(AppModel.self) private var model
    @State private var files: [WorkspaceEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("工作区文件")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Spacer()
                Button {
                    loadFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: file.isDirectory ? "folder" : "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(file.isDirectory ? Palette.accent : .secondary)
                            Text(file.name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .onAppear { loadFiles() }
        .onChange(of: model.workspacePath) { loadFiles() }
    }

    private func loadFiles() {
        let url = URL(fileURLWithPath: model.workspacePath, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        files = urls.compactMap { item -> WorkspaceEntry? in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let name = values?.name ?? item.lastPathComponent
            return WorkspaceEntry(id: item.path, name: name, isDirectory: values?.isDirectory == true)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct InfoInspectorTab: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("会话与协议信息")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)

                VStack(alignment: .leading, spacing: 8) {
                    infoRow(title: "协议版本", value: "ACP v1 (protocolVersion: 1)")
                    infoRow(title: "客户端", value: "Aureways 0.1.0")
                    infoRow(title: "传输方式", value: "JSON-RPC 2.0 (stdio NDJSON)")
                    infoRow(title: "客户端能力", value: "fs.readTextFile, fs.writeTextFile, terminal")

                    if let s = session {
                        Divider().overlay(Palette.border)
                        infoRow(title: "当前 Agent", value: s.agent.title)
                        infoRow(title: "Agent 描述", value: s.agent.subtitle)
                        infoRow(title: "启动命令", value: s.agent.launchLine)
                        infoRow(title: "工作区路径", value: s.cwd)
                        infoRow(title: "Session ID", value: s.acpSessionId ?? "（尚未建立）")
                    }
                }
                .padding(12)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

