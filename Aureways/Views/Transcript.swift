import SwiftUI

struct TranscriptView: View {
    let session: ChatSession

    @State private var viewportHeight: CGFloat = 0
    @State private var bottomEdgeY: CGFloat = 0
    @State private var composerHeight: CGFloat = 0

    private let followTolerance: CGFloat = 140
    private let bottomAnchor = "transcript-bottom-anchor"

    private var isFollowing: Bool {
        bottomEdgeY < viewportHeight + followTolerance
    }

    var body: some View {
        let blocks = TranscriptBlock.group(session.items)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                            TranscriptBlockView(
                                block: block,
                                isStreaming: session.isStreaming && index == blocks.count - 1
                            )
                            .id(block.id)
                        }
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    // 底部留白必须 >= 悬浮输入卡的实际高度，否则最后一条
                    // 消息滑到卡片底下，只从卡片下缘的缝隙里露出来。
                    .padding(.bottom, max(composerHeight + 24, 72))

                    Color.clear
                        .frame(height: 0)
                        .id(bottomAnchor)
                        .onGeometryChange(for: CGFloat.self) { geo in
                            geo.frame(in: .named("transcriptScroll")).maxY
                        } action: { bottomEdgeY = $0 }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .coordinateSpace(name: "transcriptScroll")
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.height
            } action: { viewportHeight = $0 }
            .composerBar(session: session)
            .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
            .onChange(of: session.transcriptRevision) {
                autoscroll(proxy, blocks: blocks)
            }
            .onChange(of: session.isStreaming) {
                autoscroll(proxy, blocks: blocks)
            }
            .onChange(of: session.phase) {
                if session.phase.isReady {
                    autoscroll(proxy, blocks: blocks, force: true)
                }
            }
        }
    }

    /// Follow the newest content only while the user stays near the bottom;
    /// scrolling up pauses following, and user messages always jump to bottom.
    /// Anchor 是垫在底部留白之后的标记，这样最后一条消息停在输入卡上方，
    /// 而不是贴着视口底边藏进卡片后面。
    private func autoscroll(_ proxy: ScrollViewProxy, blocks: [TranscriptBlock], force: Bool = false) {
        guard let last = blocks.last else { return }
        let lastIsUser: Bool
        if case .user = last {
            lastIsUser = true
        } else {
            lastIsUser = false
        }
        guard force || session.isReplaying || lastIsUser || isFollowing else { return }
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }
}
