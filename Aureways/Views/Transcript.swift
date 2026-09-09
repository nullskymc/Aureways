import SwiftUI

struct TranscriptView: View {
    let session: ChatSession

    @State private var composerHeight: CGFloat = 0
    @State private var stickToBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    private var displayedEntries: [TranscriptEntry] {
        #if DEBUG
        if PerfFixture.usesLegacyProjection {
            return TranscriptBlock.group(session.items, runs: session.activityRuns).map {
                TranscriptEntry(block: $0)
            }
        }
        #endif
        return session.transcriptEntries
    }

    var body: some View {
        let entries = displayedEntries
        let liveID = session.isStreaming ? entries.last?.id : nil
        ScrollView {
            // 使用稳定平滑的 VStack。块由 TranscriptBlockView.equatable() 守护，
            // 且 Markdown 全部命中 MarkdownDocumentCache，布局开销极低。
            // 避免 LazyVStack 在动态卡片卸载时高度塌陷（extent collapse）把视口强行拉回底部。
            VStack(alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    TranscriptBlockView(
                        block: entry.block,
                        version: entry.version,
                        isStreaming: session.isStreaming && entry.id == liveID
                    )
                    .equatable()
                    .id(entry.id)
                }
            }
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
        // 精确检测是否在底部边缘：当用户主动向上浏览历史时（偏移离底部 > 80pt），
        // 立即解除跟随锁定，绝不在滚动历史时突然将用户拽回底部。
        .onScrollGeometryChange(for: Bool.self) { geo in
            let maxOffset = max(0, geo.contentSize.height - geo.containerSize.height)
            let distanceFromBottom = maxOffset - geo.contentOffset.y
            return distanceFromBottom < 80
        } action: { _, atBottom in
            if stickToBottom != atBottom { stickToBottom = atBottom }
        }
        .onChange(of: composerHeight) {
            if stickToBottom {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: session.transcriptRevision) { follow(entries) }
        .onChange(of: session.isStreaming) {
            follow(entries)
            // 回合刚结束：把定稿的正文预解析掉，下次回收上屏能同步拿到高度。
            if !session.isStreaming { warmMarkdown() }
        }
        .onChange(of: session.phase) {
            if session.phase.isReady { follow(entries, force: true) }
        }
        .onAppear {
            session.ensureTranscriptProjection()
            follow(session.transcriptEntries, force: true)
        }
        .task(id: session.id) { warmMarkdown() }
    }

    /// Follow the newest content only while the user stays near the bottom;
    /// scrolling up pauses following, and user messages always jump to bottom.
    private func follow(_ entries: [TranscriptEntry], force: Bool = false) {
        guard let last = entries.last?.block else { return }
        let lastIsUser: Bool
        if case .user = last {
            lastIsUser = true
        } else {
            lastIsUser = false
        }
        if session.isReplaying || force || lastIsUser {
            stickToBottom = true
        }
        guard stickToBottom else { return }
        scrollPosition.scrollTo(edge: .bottom)
    }

    /// 后台把还没解析的 agent 正文解析掉。300 条约 54 ms，排成一队跑，换来的是
    /// 块被放置时高度就是对的。
    private func warmMarkdown() {
        MarkdownDocumentCache.shared.warm(
            session.markdownSources,
            config: AurewaysMarkdown.plain
        )
    }
}
