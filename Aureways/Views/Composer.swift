import SwiftUI

struct ComposerCard: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var currentSession: ChatSession? {
        session ?? model.selectedSession
    }

    var isStreaming: Bool {
        currentSession?.isStreaming ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: model.pickWorkspace) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                            Text(model.currentWorkspaceName)
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 4) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 11))
                        Text("本地")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)

                    if let branch = model.workspaceBranch {
                        HStack(spacing: 4) {
                            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.system(size: 11))
                            Text(branch)
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .disabled(isStreaming)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) {
                            submit()
                        }
                    }

                HStack(alignment: .center, spacing: 8) {
                    Menu {
                        if let available = currentSession?.availableCommands, !available.isEmpty {
                            Section("可用指令 (Slash Commands)") {
                                ForEach(available) { command in
                                    Button("/\(command.name) - \(command.description ?? "")") {
                                        draft = "/\(command.name) "
                                        isFocused = true
                                    }
                                }
                            }
                            Divider()
                        }
                        Section("快捷指令") {
                            Button("/help - 帮助说明") { draft = "/help "; isFocused = true }
                            Button("/clear - 清空上下文") { draft = "/clear "; isFocused = true }
                        }
                        Divider()
                        Button("切换工作区...") { model.pickWorkspace() }
                        Button("管理 Agents...") { model.isShowingCustomSheet = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Palette.cardHover, in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button {
                        model.autoApprove.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.autoApprove ? "checkmark.shield.fill" : "shield")
                                .font(.system(size: 11))
                                .foregroundStyle(model.autoApprove ? Palette.moss : .secondary)
                            Text(model.autoApprove ? "帮我批准" : "需我确认")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(model.autoApprove ? .primary : .secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(model.autoApprove ? Palette.moss.opacity(0.12) : Palette.cardHover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(model.autoApprove ? "自动批准权限已开启" : "需要手动批准工具调用")

                    Spacer()

                    Menu {
                        ForEach(model.agents) { agent in
                            Button {
                                model.selectedAgentId = agent.id
                            } label: {
                                HStack {
                                    Text(agent.title)
                                    if model.availability[agent.id] == true {
                                        Text("(可用)")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.availability[model.selectedAgent.id] == true ? Palette.moss : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)

                            Text(model.selectedAgent.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.primary)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Palette.cardHover, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    if isStreaming {
                        Button {
                            model.cancel()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.red.opacity(0.85))
                                    .frame(width: 28, height: 28)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.white)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("停止生成 (⌘.)")
                        .keyboardShortcut(".", modifiers: [.command])
                    } else {
                        Button(action: submit) {
                            ZStack {
                                Circle()
                                    .fill(canSend ? Palette.accent : Palette.cardHover)
                                    .frame(width: 28, height: 28)
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.6))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help("发送消息 (⌘Return)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 4)
            }
            .liquidGlassCard(cornerRadius: 16, isFocused: isFocused, enabled: model.useLiquidGlass)
            .frame(maxWidth: 780)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear { isFocused = true }
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText, !isStreaming else { return false }
        if let session = currentSession {
            switch session.phase {
            case .connecting: return false
            case .ready, .failed: return true
            }
        }
        return true
    }

    private var placeholder: String {
        if let s = currentSession {
            switch s.phase {
            case .connecting:
                return "正在启动 \(s.agent.title)..."
            case .failed:
                return "启动失败，发送以重试 \(s.agent.title)..."
            case .ready:
                return "向 \(s.agent.title) 发送消息..."
            }
        }
        return "输入需求或问题 (例如: 修复代码、生成功能、执行命令)..."
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        model.sendFromComposer(text: text)
    }
}

struct PermissionSheet: View {
    let prompt: PermissionPrompt
    let onDecide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.gold)
                Text("需要权限确认")
                    .font(.title3.weight(.semibold))
            }

            Text(prompt.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let input = prompt.toolCall?.rawInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("调用参数：")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(stringify(input))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack {
                Button("取消") { onDecide(.cancelled) }
                Spacer()
                ForEach(prompt.options) { option in
                    Button(option.name) {
                        onDecide(.selected(option.optionId))
                    }
                    .keyboardShortcut(option.isAllow ? .defaultAction : .cancelAction)
                    .tint(option.isAllow ? Palette.moss : .red)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 440)
    }

    private func stringify(_ json: JSONValue) -> String {
        (try? String(data: json.encode(), encoding: .utf8)) ?? ""
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("外观与特效 (Appearance)") {
                Picker("主题模式", selection: $model.appearance) {
                    Text("系统默认 (跟随 macOS)").tag("system")
                    Text("浅色模式 (Light)").tag("light")
                    Text("深色模式 (Dark)").tag("dark")
                }
                .pickerStyle(.inline)

                Toggle("毛玻璃 / 流光玻璃特效 (Liquid Glass)", isOn: $model.useLiquidGlass)
                Text("开启后将启用 macOS 原生超薄毛玻璃材质（ultraThinMaterial）与高光反射边缘。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("工作区设置") {
                LabeledContent("当前路径", value: model.workspacePath)
                Button("选择新工作区...", action: model.pickWorkspace)
            }

            Section("安全与自动化") {
                Toggle("自动批准工具权限 (Auto-approve)", isOn: $model.autoApprove)
                Text("开启后，Aureways 将自动选择首个允许选项。Grok 会话将额外传递 --always-approve。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于 Aureways") {
                Text("Aureways 是面向 Agent Client Protocol (ACP v1) 的原生 macOS 客户端。")
                Text("版本: 0.1.0 · 协议: ACP v1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}


