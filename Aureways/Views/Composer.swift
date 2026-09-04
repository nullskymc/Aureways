import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 输入补全状态机：slash 仅在第一行行首生效；mention 匹配光标前最近的 "@查询" 段。
enum CompletionMode: Equatable {
    case none
    case slash(query: String)
    case mention(query: String)
}

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
    @State private var attachments: [ComposerAttachment] = []
    @State private var editor = ComposerEditorBridge()
    @State private var completionMode: CompletionMode = .none
    @State private var completionIndex = 0
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
            .onChange(of: draft) {
                model.draftPrompt = draft
                updateCompletionMode()
            }
            .overlay(alignment: .topLeading) {
                if !completionItems.isEmpty {
                    CompletionPopup(
                        items: completionItems,
                        selectedIndex: completionIndex,
                        onSelect: { item in
                            if let index = completionItems.firstIndex(where: { $0.id == item.id }) {
                                completionIndex = index
                            }
                            confirmCompletion(item)
                        }
                    )
                    // 弹层在 overlay 里不参与布局：开合不影响 dock 高度与 transcript。
                    // 顶部对齐后上移（自身高度 + 8pt 间隙），出现在卡片上方。
                    .offset(x: 12, y: -(CompletionPopup.height(itemCount: completionItems.count) + 8))
                }
            }
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

                ComposerTextRepresentable(
                    draft: $draft,
                    isFocused: Binding(get: { isFocused }, set: { isFocused = $0 }),
                    onAttachments: { attachments.append(contentsOf: $0) },
                    onCommand: handleCommand,
                    coordinatorSink: { editor.coordinator = $0 }
                )
                .frame(height: editorHeight)
            }
            .onPreferenceChange(ComposerHeightKey.self) { measuredHeight = $0 }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            attachmentsRow

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

    /// 附件行：静态出现/消失，不做动画——dock 高度动画会抖动 transcript（既往实测约束）。
    @ViewBuilder
    private var attachmentsRow: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentChip(
                            attachment: attachment,
                            unsupported: attachment.kind == .image && imageSupport == false,
                            onRemove: { attachments.removeAll { $0.id == attachment.id } }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 6)
            }
        }
    }

    /// nil = 未知（无 session 或尚未握手），照发；false = 明确不支持，图片禁发。
    private var imageSupport: Bool? {
        let agent = displayedAgent
        if currentSession?.phase.isReady != true, currentSession != nil {
            return nil
        }
        return model.runtimes[agent.id]?.capabilities.promptCapabilities?.image
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard (hasText || !attachments.isEmpty), !isStreaming else { return false }
        if attachments.contains(where: { $0.kind == .image }), imageSupport == false {
            return false
        }
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
                ForEach(model.selectableAgents) { item in
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
            .help("新对话将使用此 Agent，并记为下次默认。已打开的会话不会跟着变。")
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
                help: "切换本会话使用的模型",
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
                help: "切换本会话模式",
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
        let pendingAttachments = attachments
        draft = ""
        attachments = []
        model.sendFromComposer(text: text, attachments: pendingAttachments)
    }

    private func handleCommand(_ command: ComposerCommand) -> Bool {
        switch command {
        case .confirm:
            if let item = completionItems[safe: completionIndex] {
                confirmCompletion(item)
                return true
            }
            submit()
            return true
        case .tab:
            if let item = completionItems[safe: completionIndex] {
                confirmCompletion(item)
                return true
            }
            return false
        case .moveUp:
            guard !completionItems.isEmpty else { return false }
            completionIndex = max(0, completionIndex - 1)
            return true
        case .moveDown:
            guard !completionItems.isEmpty else { return false }
            completionIndex = min(completionItems.count - 1, completionIndex + 1)
            return true
        case .cancel:
            if completionMode != .none {
                completionMode = .none
                return true
            }
            return false
        }
    }

    private var completionItems: [CompletionItem] {
        switch completionMode {
        case .none:
            return []
        case .slash(let query):
            var entries: [(name: String, description: String?)] =
                (currentSession?.availableCommands ?? []).map { ($0.name, $0.description) }
            if !entries.contains(where: { $0.name == "help" }) { entries.append(("help", "帮助说明")) }
            if !entries.contains(where: { $0.name == "clear" }) { entries.append(("clear", "清空上下文")) }
            return entries
                .filter { query.isEmpty || $0.name.lowercased().hasPrefix(query.lowercased()) }
                .map {
                    CompletionItem(id: "slash-\($0.name)", kind: .slash, title: "/\($0.name)", subtitle: $0.description, file: nil)
                }
        case .mention(let query):
            return model.fileIndex.search(query).map { file in
                CompletionItem(id: "file-\(file.relativePath)", kind: .file, title: file.relativePath, subtitle: nil, file: file)
            }
        }
    }

    private func updateCompletionMode() {
        guard let textView = editor.coordinator?.textView, !textView.hasMarkedText() else {
            completionMode = .none
            return
        }
        let cursor = textView.selectedRange().location
        let before = (draft as NSString).substring(to: min(cursor, (draft as NSString).length))

        if before.hasPrefix("/"), !before.contains("\n") {
            let query = String(before.dropFirst())
            // 命令参数阶段不再补全
            completionMode = query.contains(" ") ? .none : .slash(query: query)
            completionIndex = 0
            return
        }

        let segment = before
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .last ?? Substring()
        if segment.hasPrefix("@") {
            model.fileIndex.ensureScanned(root: model.workspacePath)
            completionMode = .mention(query: String(segment.dropFirst()))
        } else {
            completionMode = .none
        }
        completionIndex = 0
    }

    private func confirmCompletion(_ item: CompletionItem) {
        switch item.kind {
        case .slash:
            editor.coordinator?.setDraft("\(item.title) ")
            completionMode = .none
            completionIndex = 0
            isFocused = true
        case .file:
            guard let file = item.file, let textView = editor.coordinator?.textView else { return }
            let cursor = textView.selectedRange().location
            let nsDraft = draft as NSString
            let before = nsDraft.substring(to: min(cursor, nsDraft.length))
            let segment = before
                .split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .last ?? Substring()
            guard segment.hasPrefix("@") else {
                completionMode = .none
                return
            }
            editor.coordinator?.insert("\(file.relativePath) ", replacing: NSRange(location: cursor - segment.count, length: segment.count))
            let absolutePath = URL(fileURLWithPath: model.workspacePath).appendingPathComponent(file.relativePath).path
            attachments.append(ComposerAttachment(
                kind: .file,
                name: (file.relativePath as NSString).lastPathComponent,
                url: URL(fileURLWithPath: absolutePath),
                mimeType: UTType(filenameExtension: (file.relativePath as NSString).pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream",
                imageData: nil,
                thumbnail: nil
            ))
            completionMode = .none
            completionIndex = 0
            isFocused = true
        }
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: ComposerAttachment
    let unsupported: Bool
    let onRemove: () -> Void

    var body: some View {
        Group {
            switch attachment.kind {
            case .image:
                imageThumb
            case .file:
                fileChip
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .help("移除附件")
            .offset(x: 5, y: -5)
        }
    }

    private var imageThumb: some View {
        Group {
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        )
        .overlay(alignment: .bottomLeading) {
            if unsupported {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.gold)
                    .padding(3)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .help("当前 Agent 不支持图片输入，请移除后发送")
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var fileChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.cardHover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(height: 28)
        .help(attachment.name)
    }
}
