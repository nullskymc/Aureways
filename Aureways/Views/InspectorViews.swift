import AppKit
import SwiftUI

// MARK: - Inspector Pane View (Right Panel)

struct InspectorPaneView: View {
    @Environment(AppModel.self) private var model
    /// 拖动状态全部收进引用类型：连续拖动时不写 observable 状态，视图只在
    /// 开始 / 结束两个边沿失效。详见 `SplitResizeEngine`。
    @StateObject private var resize = SplitResizeEngine()

    var body: some View {
        // 拖动期间把内容的提案宽度钉在拖动开始那一刻：子树不再重新换行、重新测高、
        // 重排列宽，每帧只剩外层裁剪框在动。松手后 frozenWidth 归零，一次性按最终
        // 宽度排一遍——这才是"停手后再渲染"。
        //
        // 必须用 `FrozenWidthLayout` 而不是 `.frame(width:)`：后者会把固定宽度当成
        // 内容的理想宽度往上传，`NavigationSplitView` 的分栏据此把列宽钉死（拉到最大
        // 宽度后拉不回来）。容器尺寸恒等于父级提案就不会有这个问题。
        FrozenWidthLayout(frozenWidth: resize.frozenWidth) {
            ZStack {
                // 所有标签页保持存活：切走只是隐藏，终端输出和编辑器文本不丢。
                ForEach(model.paneTabs) { tab in
                    let isActive = model.activePaneTabId == tab.id
                    tabContent(tab, isActive: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .zIndex(isActive ? 1 : 0)
                }
            }
        }
        .clipped()
        .background(Palette.inspectorBg)
        .overlay {
            // PERF-02: 纯色 scrim 替代 .regularMaterial，消除分栏拖动时 GPU 每帧全窗格材质重采样模糊
            Palette.inspectorBg
                .opacity(0.85)
                .opacity(resize.isResizing ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: resize.isResizing)
                .allowsHitTesting(false)
        }
        .environment(\.inspectorResizing, resize.isResizing)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { _, width in
            resize.note(width: width)
        }
        .onAppear { resize.beginMonitoring() }
        .onDisappear { resize.reset() }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Palette.splitDivider)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .alert("文件已被外部修改".localized, isPresented: Binding(
            get: { model.pendingSavePath != nil },
            set: { if !$0 { model.cancelPendingSave() } }
        )) {
            Button("仍然覆盖".localized) {
                if let path = model.pendingSavePath, let content = model.pendingSaveContent {
                    model.writeFileTab(path: path, content: content)
                } else {
                    model.cancelPendingSave()
                }
            }
            Button("放弃我的修改".localized, role: .destructive) {
                if let path = model.pendingSavePath {
                    model.cancelPendingSave()
                    model.reloadFileTab(path)
                }
            }
            Button("取消".localized, role: .cancel) {
                model.cancelPendingSave()
            }
        } message: {
            Text("“%@” 在你打开后被外部修改过，保存会覆盖新内容。".localized(
                model.pendingSavePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            ))
        }
        .alert("有未保存的修改".localized, isPresented: Binding(
            get: { model.pendingClosePath != nil },
            set: { if !$0 { model.pendingClosePath = nil } }
        )) {
            Button("保存并关闭".localized) {
                model.resolvePendingCloseFileTab(save: true)
            }
            Button("不保存".localized, role: .destructive) {
                model.resolvePendingCloseFileTab(save: false)
            }
            Button("取消".localized, role: .cancel) {
                model.pendingClosePath = nil
            }
        } message: {
            Text("“%@” 还有未保存的修改。".localized(
                model.pendingClosePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            ))
        }
        .alert("重新载入会丢失未保存的修改".localized, isPresented: Binding(
            get: { model.pendingReloadPath != nil },
            set: { if !$0 { model.pendingReloadPath = nil } }
        )) {
            Button("重新载入".localized, role: .destructive) {
                model.confirmPendingReload()
            }
            Button("取消".localized, role: .cancel) {
                model.pendingReloadPath = nil
            }
        } message: {
            Text("“%@” 有未保存的修改，从磁盘重新载入会丢弃它们。".localized(
                model.pendingReloadPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            ))
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: PaneTab, isActive: Bool) -> some View {
        switch tab {
        case .browser:
            FileBrowserTabView(isActive: isActive)
        case .info:
            InfoInspectorTab(session: model.selectedSession)
        case .file(let path):
            FileEditorTabView(path: path, isActive: isActive)
        case .terminal(let id):
            if let terminal = model.interactiveTerminals[id] {
                TerminalTabView(terminal: terminal, isActive: isActive)
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
                HStack(spacing: 9) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(session?.agent.title ?? "Aureways")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                        Text(session == nil ? "尚未打开会话".localized : "当前会话".localized)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.badgeBg.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 8) {
                    infoRow(title: "客户端".localized, value: "Aureways \(AppInfo.version)")

                    if let s = session {
                        infoRow(title: "当前 Agent".localized, value: s.agent.title)
                        if !s.agent.subtitle.isEmpty, s.agent.subtitle != s.agent.title {
                            infoRow(title: "来源".localized, value: s.agent.subtitle)
                        }
                        infoRow(title: "启动命令".localized, value: s.agent.launchLine)
                        infoRow(title: "工作区".localized, value: s.cwd)
                        infoRow(title: "会话 ID".localized, value: s.acpSessionId ?? "尚未建立".localized)
                        if let mode = s.currentModeId, !mode.isEmpty {
                            infoRow(title: "当前模式".localized, value: s.modeChoices.first(where: { $0.id == mode })?.name ?? mode)
                        }
                        if let usage = s.usage {
                            infoRow(title: "上下文".localized, value: usageLabel(usage))
                            usageBar(usage)
                        }
                        if !s.reportedMcpServers.isEmpty {
                            infoRow(
                                title: "MCP",
                                value: s.reportedMcpServers.map(\.name).joined(separator: "、")
                            )
                        }
                    }
                }
                .padding(12)
                .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let s = session, s.phase.isReady, !s.configOptions.isEmpty {
                    Text("会话选项".localized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("由当前 Agent 提供，只作用于本会话。".localized)
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
                    get: { option.selectedString ?? "" },
                    set: { model.setSessionConfig(session, configId: option.id, value: .string($0)) }
                )) {
                    ForEach(Array(SessionMode.menuSections(from: option.options).enumerated()), id: \.offset) { _, section in
                        if let title = section.title {
                            Section(title) {
                                ForEach(section.items) { choice in
                                    Text(choice.name).tag(choice.id)
                                }
                            }
                        } else {
                            ForEach(section.items) { choice in
                                Text(choice.labeledName).tag(choice.id)
                            }
                        }
                    }
                }
                .labelsHidden()
            } else if let value = option.value?.stringValue {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private func usageLabel(_ usage: SessionUsage) -> String {
        var parts = ["\(usage.used) / \(usage.size)"]
        if let amount = usage.costAmount {
            let currency = usage.costCurrency ?? ""
            parts.append(String(format: "%.4f %@", amount, currency).trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func usageBar(_ usage: SessionUsage) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.badgeBg)
                Capsule()
                    .fill(usage.percent > 0.9 ? Color.red : Palette.accent)
                    .frame(width: max(4, geo.size.width * usage.percent))
            }
        }
        .frame(height: 4)
        .padding(.top, 2)
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
