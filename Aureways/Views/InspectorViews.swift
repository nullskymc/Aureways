import SwiftUI

// MARK: - Inspector Pane View (Right Panel)

struct InspectorPaneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
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
                        .glassRowHighlight(
                            isSelected: model.selectedInspectorTab == tab,
                            isHovered: false,
                            cornerRadius: 6
                        )
                    }
                    .buttonStyle(.plain)
                    .help(tab.rawValue)
                }
                Spacer()
            }
            .padding(8)

            Divider()

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
        .liquidGlassBackdrop()
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
                Text("按 Agent 进程归因：同一 Agent 的多个会话共用一个进程，这里可能混入其它会话触发的读写。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(ops) { op in
                            HStack(spacing: 8) {
                                Text(op.type.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(op.type == "write" ? Palette.moss : Palette.sky)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

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
                            .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                Text("stderr 来自 Agent 进程，同一 Agent 的多个会话共用，可能混入其它会话的日志。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                ScrollView {
                    Text(logs.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .scrollContentBackground(.hidden)
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
                    infoRow(title: "客户端", value: "Aureways \(AppInfo.version)")
                    infoRow(title: "传输方式", value: "JSON-RPC 2.0 (stdio NDJSON)")
                    infoRow(title: "客户端能力", value: "fs.readTextFile, fs.writeTextFile, terminal")

                    if let s = session {
                        Divider()
                        infoRow(title: "当前 Agent", value: s.agent.title)
                        infoRow(title: "Agent 描述", value: s.agent.subtitle)
                        infoRow(title: "启动命令", value: s.agent.launchLine)
                        infoRow(title: "工作区路径", value: s.cwd)
                        infoRow(title: "Session ID", value: s.acpSessionId ?? "（尚未建立）")
                        if let mode = s.currentModeId, !mode.isEmpty {
                            infoRow(title: "当前模式", value: s.modeChoices.first(where: { $0.id == mode })?.name ?? mode)
                        }
                    }
                }
                .padding(12)
                .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let s = session, s.phase.isReady, !s.configOptions.isEmpty {
                    Text("会话配置（ACP 透传）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text("由当前 harness 声明，不写入 Aureways 自己的设置。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(s.configOptions) { option in
                            sessionConfigRow(session: s, option: option)
                        }
                    }
                    .padding(12)
                    .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func sessionConfigRow(session: ChatSession, option: SessionConfigOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(option.name)
                .font(.system(size: 11, weight: .semibold))
            if let description = option.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if option.isBoolean {
                Toggle("", isOn: Binding(
                    get: { option.value?.boolValue ?? false },
                    set: { model.setSessionConfig(session, configId: option.id, value: .bool($0)) }
                ))
                .labelsHidden()
            } else if !option.options.isEmpty {
                Picker("", selection: Binding(
                    get: { option.value?.stringValue ?? "" },
                    set: { model.setSessionConfig(session, configId: option.id, value: .string($0)) }
                )) {
                    ForEach(option.options) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .labelsHidden()
            } else if let value = option.value?.stringValue {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
            }
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

