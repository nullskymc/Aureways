import AppKit
import SwiftUI

/// Floating input card only — not a system bottom bar.
/// Overlay is only as wide as the card so it does not steal scroll/clicks.
struct ComposerDock: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession?

    var body: some View {
        VStack(spacing: 8) {
            if let pending = pendingPermission {
                // 不加插入动画：过渡期间 dock 高度逐帧变化，会连续触发
                // 转录区底部留白重算与 scrollTo，LazyVStack 会渲染崩坏。
                PermissionCard(
                    session: pending.session,
                    prompt: pending.prompt,
                    showsSessionBadge: pending.session.id != session?.id
                )
            }
            ComposerCard(session: session)
        }
        .frame(maxWidth: Chrome.composerMaxWidth)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
            }
        }
    }

    /// 待批准的权限请求：优先当前会话，其次其余会话——
    /// 新建对话落地页上也能批准后台会话的请求，替代原来的模态弹窗。
    private var pendingPermission: (session: ChatSession, prompt: PermissionPrompt)? {
        if let session, let prompt = session.pendingPermission {
            return (session, prompt)
        }
        for candidate in model.sessions {
            if let prompt = candidate.pendingPermission {
                return (candidate, prompt)
            }
        }
        return nil
    }
}

extension View {
    func composerBar(session: ChatSession?) -> some View {
        modifier(ComposerBarModifier(session: session))
    }
}

private struct ComposerBarModifier: ViewModifier {
    let session: ChatSession?

    func body(content: Content) -> some View {
        // Overlay, not safeAreaInset: the transcript behind must stay clear
        // so glass can sample the conversation. Alignment `.bottom` centers
        // the capped card; do not expand the overlay to full width.
        content.overlay(alignment: .bottom) {
            ComposerDock(session: session)
        }
    }
}

struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 20
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ComposerCard: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession?
    @State private var draft = ""
    @State private var measuredHeight: CGFloat = 20
    @FocusState private var isFocused: Bool

    private let editorMinHeight: CGFloat = 20
    private let editorMaxHeight: CGFloat = 126

    var currentSession: ChatSession? {
        session ?? model.selectedSession
    }

    var isStreaming: Bool {
        currentSession?.isStreaming ?? false
    }

    private var editorHeight: CGFloat {
        min(editorMaxHeight, max(editorMinHeight, measuredHeight + 2))
    }

    var body: some View {
        cardStack
            .onAppear {
                draft = model.draftPrompt
                isFocused = true
            }
            .onChange(of: draft) { model.draftPrompt = draft }
    }

    private var cardStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text(draft.isEmpty ? " " : draft)
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
                        }
                    }

                if draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draft)
                    .font(.system(size: 13.5))
                    // 抵消 NSTextView 自带的 ~5pt lineFragmentPadding，
                    // 让光标/输入文字与占位符在同一左边缘对齐。
                    .padding(.leading, -5)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(editorHeight >= editorMaxHeight ? .automatic : .hidden)
                    .frame(height: editorHeight)
                    .focused($isFocused)
                    .onKeyPress(keys: [.return]) { press in
                        guard press.phase == .down, press.modifiers.isEmpty, !Self.hasMarkedText else {
                            return .ignored
                        }
                        submit()
                        return .handled
                    }
            }
            .onPreferenceChange(ComposerHeightKey.self) { measuredHeight = $0 }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            controlRow
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .liquidGlassCard(cornerRadius: Chrome.cardRadius, veil: 0.65)
        .contentShape(RoundedRectangle(cornerRadius: Chrome.cardRadius, style: .continuous))
    }

    private var controlRow: some View {
        // Glass 按钮不放 GlassEffectContainer：container 只服务 glassEffect 视图，
        // 包住 buttonStyle(.glass) 控件会吞掉 bezel（实测截图验证）。
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
                Button("添加工作区...") { model.addWorkspace() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.glass)

            autoApproveButton

            Spacer(minLength: 8)

            harnessChip
            sessionModelChip
            sessionModeChip

            if isStreaming {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
                .help("停止生成 (⌘.)")
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            canSend ? Color.primary : Color.primary.opacity(0.08),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(canSend ? "发送消息 (⌘Return)" : "输入内容后可发送")
            }
        }
    }

    @ViewBuilder
    private var autoApproveButton: some View {
        let base = Button {
            model.autoApprove.toggle()
        } label: {
            Text(model.autoApprove ? "帮我批准" : "需我确认")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .help("开启后，Agent 读写文件或执行命令时不再弹出确认，由客户端代为批准。关闭则每次工具调用都需你确认。")

        if model.autoApprove {
            base.buttonStyle(.glass(.regular.tint(Palette.moss)))
        } else {
            base.buttonStyle(.glass)
        }
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText, !isStreaming else { return false }
        if let session = currentSession {
            switch session.phase {
            case .connecting: return false
            case .ready, .failed, .idle: return true
            }
        }
        return true
    }

    private var placeholder: String {
        if let s = currentSession {
            switch s.phase {
            case .connecting:
                return "正在启动 \(s.agent.title)..."
            case .idle:
                return "发送以恢复 \(s.agent.title) 会话..."
            case .failed:
                return "启动失败，发送以重试 \(s.agent.title)..."
            case .ready:
                return "向 \(s.agent.title) 发送消息..."
            }
        }
        return "向 \(model.selectedAgent.title) 发送消息..."
    }

    private var displayedAgent: AgentProfile {
        currentSession?.agent ?? model.selectedAgent
    }

    @ViewBuilder
    private var harnessChip: some View {
        let agent = displayedAgent
        let available = model.availability[agent.id] == true
        let chip = HStack(spacing: 5) {
            Circle()
                .fill(available ? Palette.moss : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(agent.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
            if currentSession == nil {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }

        if currentSession == nil {
            Menu {
                ForEach(model.agents) { item in
                    Button {
                        model.selectedAgentId = item.id
                    } label: {
                        HStack {
                            Text(item.title)
                            if model.availability[item.id] == true {
                                Text("(可用)")
                            }
                        }
                    }
                }
            } label: {
                chip
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.glass)
            .help("新对话将使用此 harness，并记为下次默认。已打开的会话不会跟着变。")
        } else {
            chip
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .liquidGlassCapsule(interactive: false)
                .help("本会话已绑定 \(agent.title)，不能中途更换。新对话请先点 ⌘N。")
        }
    }

    @ViewBuilder
    private var sessionModelChip: some View {
        if let session = currentSession,
           session.phase.isReady,
           let option = session.modelOption,
           !option.options.isEmpty {
            sessionSelectChip(
                title: option.options.first(where: { $0.id == option.value?.stringValue })?.name ?? option.name,
                help: "本会话模型，由当前 harness 经 ACP 声明",
                choices: option.options,
                selectedId: option.value?.stringValue
            ) { id in
                model.setSessionConfig(session, configId: option.id, value: .string(id))
            }
        }
    }

    @ViewBuilder
    private var sessionModeChip: some View {
        if let session = currentSession, session.phase.isReady, !session.modeChoices.isEmpty {
            sessionSelectChip(
                title: session.modeChoices.first(where: { $0.id == session.currentModeId })?.name ?? "模式",
                help: "本会话模式，由当前 harness 经 ACP 声明",
                choices: session.modeChoices,
                selectedId: session.currentModeId
            ) { id in
                model.setSessionMode(session, modeId: id)
            }
        }
    }

    private func sessionSelectChip(
        title: String,
        help: String,
        choices: [SessionMode],
        selectedId: String?,
        onPick: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    onPick(choice.id)
                } label: {
                    HStack {
                        Text(choice.name)
                        if selectedId == choice.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.glass)
        .help(help)
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        model.sendFromComposer(text: text)
    }

    /// IME 组词确认也走 Return；此时放行给文本视图，避免把拼音串直接提交。
    private static var hasMarkedText: Bool {
        guard let window = NSApp.keyWindow else { return false }
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if let textView = current as? NSTextView, textView.hasMarkedText() {
                return true
            }
            responder = current.nextResponder
        }
        return false
    }
}
