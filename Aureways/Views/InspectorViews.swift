import AppKit
import SwiftUI

// MARK: - Inspector Pane View (Right Panel)

struct InspectorPaneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PaneTabBar()

            ZStack {
                // 所有标签页保持存活：切走只是隐藏，终端输出和编辑器文本不丢。
                ForEach(model.paneTabs) { tab in
                    let isActive = model.activePaneTabId == tab.id
                    tabContent(tab)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("文件已被外部修改", isPresented: Binding(
            get: { model.pendingSavePath != nil },
            set: { if !$0 { model.cancelPendingSave() } }
        )) {
            Button("仍然覆盖") {
                if let path = model.pendingSavePath, let content = model.pendingSaveContent {
                    model.writeFileTab(path: path, content: content)
                } else {
                    model.cancelPendingSave()
                }
            }
            Button("放弃我的修改", role: .destructive) {
                if let path = model.pendingSavePath {
                    model.cancelPendingSave()
                    model.reloadFileTab(path)
                }
            }
            Button("取消", role: .cancel) {
                model.cancelPendingSave()
            }
        } message: {
            Text("“\(model.pendingSavePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")” 在你打开后被外部修改过，保存会覆盖新内容。")
        }
        .alert("有未保存的修改", isPresented: Binding(
            get: { model.pendingClosePath != nil },
            set: { if !$0 { model.pendingClosePath = nil } }
        )) {
            Button("保存并关闭") {
                model.resolvePendingCloseFileTab(save: true)
            }
            Button("不保存", role: .destructive) {
                model.resolvePendingCloseFileTab(save: false)
            }
            Button("取消", role: .cancel) {
                model.pendingClosePath = nil
            }
        } message: {
            Text("“\(model.pendingClosePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")” 还有未保存的修改。")
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: PaneTab) -> some View {
        switch tab {
        case .browser:
            FileBrowserTabView()
        case .info:
            InfoInspectorTab(session: model.selectedSession)
        case .file(let path):
            FileEditorTabView(path: path)
        case .terminal(let id):
            if let terminal = model.interactiveTerminals[id] {
                TerminalTabView(terminal: terminal)
            }
        }
    }
}

// MARK: - Info Tab

struct InfoInspectorTab: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("会话与协议信息")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
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
