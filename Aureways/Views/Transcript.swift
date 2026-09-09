import SwiftUI

struct TranscriptView: View {
    let session: ChatSession

    @State private var composerHeight: CGFloat = 0
    @State private var stickToBottom = true
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    @State private var rowWindow = TranscriptWindow.empty
    @State private var heightCache = TranscriptHeightCache()
    @State private var chrome = TranscriptChromeState()

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
        let window = resolvedWindow(for: entries)
        ScrollView {
            // Visible rows only. Everything above / below is a spacer sized from
            // the height cache, so inspector open and split-pane drags re-typeset
            // on-screen markdown rather than the whole transcript.
            VStack(spacing: 0) {
                if window.topHeight > 0 {
                    Color.clear
                        .frame(height: window.topHeight)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: TranscriptVirtualizer.spacing) {
                    ForEach(entries[window.start..<window.end]) { entry in
                        TranscriptBlockView(
                            block: entry.block,
                            version: entry.version,
                            isStreaming: session.isStreaming && entry.id == liveID,
                            chrome: chrome
                        )
                        .equatable()
                        .id(entry.id)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { _, height in
                            heightCache.set(entry.id, height)
                        }
                    }
                }
                .scrollTargetLayout()
                if window.bottomHeight > 0 {
                    Color.clear
                        .frame(height: window.bottomHeight)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: 780, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .frame(maxWidth: .infinity)
            .transaction { $0.animation = nil }
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
        // 未放置部分的高度是缓存值，拿绝对偏移做判断会随估算漂移。
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { visible in
            guard let last = entries.last?.id else { return }
            let atBottom = visible.contains(last)
            if stickToBottom != atBottom { stickToBottom = atBottom }
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(offset: geo.contentOffset.y, viewport: geo.containerSize.height)
        } action: { _, metrics in
            heightCache.lastOffset = metrics.offset
            heightCache.lastViewport = metrics.viewport
            // First layout reports offset 0 before scrollTo(bottom) lands. Keep
            // the window pinned to the end so opening a long session does not
            // flash the top of the transcript.
            let offset = (stickToBottom && metrics.offset < 8) ? CGFloat.infinity : metrics.offset
            applyWindow(entries: entries, offset: offset, viewport: metrics.viewport)
        }
        .onChange(of: composerHeight) { follow(entries) }
        .onChange(of: session.transcriptRevision) {
            heightCache.prune(keeping: Set(entries.map(\.id)))
            applyWindow(
                entries: entries,
                offset: stickToBottom ? .infinity : heightCache.lastOffset,
                viewport: heightCache.lastViewport
            )
            follow(entries)
        }
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
            applyWindow(
                entries: session.transcriptEntries,
                offset: .infinity,
                viewport: heightCache.lastViewport
            )
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

    private func resolvedWindow(for entries: [TranscriptEntry]) -> TranscriptWindow {
        if rowWindow == .empty && !entries.isEmpty {
            return TranscriptVirtualizer.window(
                rowHeights: heightCache.rowHeights(for: entries),
                offset: .infinity,
                viewport: heightCache.lastViewport
            )
        }
        return rowWindow.clamped(to: entries.count)
    }

    private func applyWindow(entries: [TranscriptEntry], offset: CGFloat, viewport: CGFloat) {
        let next = TranscriptVirtualizer.window(
            rowHeights: heightCache.rowHeights(for: entries),
            offset: offset,
            viewport: viewport
        )
        if next != rowWindow { rowWindow = next }
    }

    /// 后台把还没解析的 agent 正文解析掉。300 条约 54 ms，排成一队跑，换来的是
    /// 块被放置时高度就是对的——窗口里的 spacer 靠这一点，而不是 LazyVStack 的估算。
    private func warmMarkdown() {
        MarkdownDocumentCache.shared.warm(
            session.markdownSources,
            config: AurewaysMarkdown.plain
        )
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var viewport: CGFloat
}
