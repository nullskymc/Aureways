import SwiftUI

struct TranscriptView: View {
    let session: ChatSession

    @State private var composerHeight: CGFloat = 0
    @State private var stickToBottom = true
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)

    var body: some View {
        let blocks = TranscriptBlock.group(session.items, runs: session.activityRuns)
        let liveID = session.isStreaming ? blocks.last?.id : nil
        ScrollView {
            // 一律虚拟化。历史一度走 eager VStack，因为库的 MarkdownView 在解析
            // 落地前高度是 0，LazyVStack 会把整段历史当成空的、进会话一片空白。
            // 现在解析结果由 MarkdownDocumentCache 持有，块在 init 就有真实内容，
            // 前提不再成立——而 eager 的代价是每帧布局开销随转录长度线性增长。
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(blocks) { block in
                    TranscriptBlockView(
                        block: block,
                        isStreaming: session.isStreaming && block.id == liveID
                    )
                    .equatable()
                    .id(block.id)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 780)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .frame(maxWidth: .infinity)
        }
        // 输入卡是浮在画布上的 overlay，所以留白得由滚动区自己让出来。用
        // safeAreaPadding 而不是塞在 stack 里的 padding：scrollTo(edge:) 认安全区，
        // 最后一条消息会停在卡片上方，而不是滑到卡片底下。
        .safeAreaPadding(.bottom, max(composerHeight + 24, 72))
        .scrollPosition($scrollPosition)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .composerBar(session: session)
        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
        // 位置跟随只认「最后一块是否可见」，不读 contentOffset / contentSize：
        // 虚拟化下未放置部分的高度是估算值，拿绝对偏移做判断会随估算漂移。
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { visible in
            guard let last = blocks.last?.id else { return }
            let atBottom = visible.contains(last)
            // 写之前守一下：这样这个布尔只在边界翻转，否则每次可见集变化都会让
            // body 重算一遍，连带整段历史重新分组。
            if stickToBottom != atBottom { stickToBottom = atBottom }
        }
        .onChange(of: composerHeight) { follow(blocks) }
        .onChange(of: session.transcriptRevision) { follow(blocks) }
        .onChange(of: session.isStreaming) {
            follow(blocks)
            // 回合刚结束：把定稿的正文预解析掉，下次回收上屏能同步拿到高度。
            if !session.isStreaming { warmMarkdown() }
        }
        .onChange(of: session.phase) {
            if session.phase.isReady { follow(blocks, force: true) }
        }
        .onAppear { follow(blocks, force: true) }
        .task(id: session.id) { warmMarkdown() }
    }

    /// Follow the newest content only while the user stays near the bottom;
    /// scrolling up pauses following, and user messages always jump to bottom.
    private func follow(_ blocks: [TranscriptBlock], force: Bool = false) {
        guard let last = blocks.last else { return }
        let lastIsUser: Bool
        if case .user = last {
            lastIsUser = true
        } else {
            lastIsUser = false
        }
        if lastIsUser || session.isReplaying || force {
            stickToBottom = true
        }
        guard stickToBottom else { return }
        scrollPosition.scrollTo(edge: .bottom)
    }

    /// 后台把还没解析的 agent 正文解析掉。300 条约 54 ms，排成一队跑，换来的是
    /// 块被放置时高度就是对的——LazyVStack 的估算依赖这一点。
    private func warmMarkdown() {
        MarkdownDocumentCache.shared.warm(
            session.markdownSources,
            config: AurewaysMarkdown.plain
        )
    }
}
