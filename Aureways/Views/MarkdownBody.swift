import AppKit
import SwiftStreamingMarkdown
import SwiftUI

/// Agent 正文交给 vendored SwiftStreamingMarkdown（cmark-gfm）。
/// 字体对齐对话画布 13.5pt；颜色用 Palette / 系统语义色，不走 Copilot 资源。
///
/// 用 `DocumentView`（渲染已解析文档）而不是 `MarkdownView`（自己在视图里解析）：
/// 解析结果存在 `MarkdownDocumentCache` 里，回收重建时能在 `init` 同步拿到，块一
/// 放上去就有真实高度——窗口化对话流的 spacer 高度依赖这一点。
///
/// 流式不能对每个 token 开一次 parse：`.task(id: source)` 取消了旧任务也不会停掉
/// 已经在跑的 cmark，旧结果仍会写回 `@State`，公式会先退回旧态再跳到新态。
/// 改成单通道：同一时刻只 parse 最新快照，中间态丢掉。
struct MarkdownBody: View {
    let source: String
    var isStreaming: Bool
    /// Long workbench previews: only build on-screen blocks. Transcript stays eager.
    var lazyBlocks: Bool = false

    @State private var document: MarkdownParseResult?
    @State private var requestedGeneration = 0
    @StateObject private var streamParser = MarkdownStreamParser()

    init(source: String, isStreaming: Bool = false, lazyBlocks: Bool = false) {
        self.source = source
        self.isStreaming = isStreaming
        self.lazyBlocks = lazyBlocks
        let cached = MarkdownDocumentCache.shared.cached(source).map {
            MarkdownParseResult(source: source, generation: 0, document: $0)
        }
        _document = State(initialValue: cached)
    }

    private var config: MarkdownRenderConfig {
        isStreaming ? AurewaysMarkdown.animated : AurewaysMarkdown.plain
    }

    var body: some View {
        Group {
            if let document {
                DocumentView(
                    renderableDocument: document.document,
                    config: config,
                    lazyBlocks: lazyBlocks
                )
            } else {
                // 解析落地前用同字号明文占位。高度只是近似，但远好过 0——
                // 高度 0 会让虚拟化的 stack 把这条消息当成不存在。
                Text(source)
                    .font(.system(size: AurewaysMarkdown.body))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            enqueueParse()
        }
        .onDisappear {
            requestedGeneration = streamParser.cancel()
        }
        .onChange(of: source) {
            enqueueParse()
        }
        .onChange(of: isStreaming) {
            enqueueParse()
        }
        .onChange(of: streamParser.result) { _, result in
            guard let result,
                  result.source == source,
                  result.generation == requestedGeneration
            else { return }
            if document?.document != result.document { document = result }
        }
    }

    private func enqueueParse() {
        if let cached = MarkdownDocumentCache.shared.cached(source) {
            requestedGeneration = streamParser.cancel()
            let result = MarkdownParseResult(
                source: source,
                generation: requestedGeneration,
                document: cached
            )
            if document?.document != cached { document = result }
            return
        }
        if !isStreaming, let currentDocument = document, currentDocument.source == source {
            requestedGeneration = streamParser.cancel()
            let finalDocument = MarkdownDocumentCache.shared.store(source, currentDocument.document)
            let result = MarkdownParseResult(
                source: source,
                generation: requestedGeneration,
                document: finalDocument
            )
            if currentDocument.document != finalDocument { document = result }
            return
        }
        requestedGeneration = streamParser.request(
            source: source,
            config: config,
            store: !isStreaming
        )
    }
}

struct MarkdownParseResult: Equatable {
    let source: String
    let generation: Int
    let document: RenderableDocument
}

/// Serializes streaming parses so CPU tracks parse time, not token rate.
///
/// While a parse is in flight, newer snapshots only replace `latest`. When the
/// in-flight parse finishes, a stale result is discarded and the newest source
/// is parsed next. One `MarkdownBody` owns one of these, so two visible
/// messages cannot steal each other's work.
@MainActor
final class MarkdownStreamParser: ObservableObject {
    typealias Parse = @Sendable (String, MarkdownRenderConfig) async -> RenderableDocument

    @Published private(set) var result: MarkdownParseResult?

    private struct Work {
        let source: String
        let config: MarkdownRenderConfig
        let store: Bool
        let generation: Int
    }

    private let parse: Parse
    private var latest: Work?
    private var generation = 0
    private var pumpTask: Task<Void, Never>?
    #if DEBUG
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(parse: @escaping Parse = MarkdownStreamParser.parse) {
        self.parse = parse
    }

    @discardableResult
    func request(source: String, config: MarkdownRenderConfig, store: Bool) -> Int {
        generation += 1
        let requestGeneration = generation
        if let cached = MarkdownDocumentCache.shared.cached(source) {
            latest = nil
            publish(source: source, generation: requestGeneration, document: cached)
            return requestGeneration
        }
        latest = Work(
            source: source,
            config: config,
            store: store,
            generation: requestGeneration
        )
        startPumpIfNeeded()
        return requestGeneration
    }

    @discardableResult
    func cancel() -> Int {
        generation += 1
        latest = nil
        pumpTask?.cancel()
        return generation
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        let parse = parse
        pumpTask = Task { [weak self] in
            while let work = self?.takeLatest() {
                let document = await parse(work.source, work.config)
                guard let self else { return }
                if Task.isCancelled { break }
                guard work.generation == self.generation,
                      self.latest == nil
                else { continue }
                let publishedDocument: RenderableDocument
                if work.store {
                    publishedDocument = MarkdownDocumentCache.shared.store(work.source, document)
                } else {
                    publishedDocument = document
                }
                self.publish(
                    source: work.source,
                    generation: work.generation,
                    document: publishedDocument
                )
            }
            self?.pumpFinished()
        }
    }

    private func takeLatest() -> Work? {
        defer { latest = nil }
        return latest
    }

    private func pumpFinished() {
        pumpTask = nil
        if latest != nil {
            startPumpIfNeeded()
            return
        }
        #if DEBUG
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        #endif
    }

    #if DEBUG
    func waitUntilIdle() async {
        guard pumpTask != nil || latest != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
    #endif

    private func publish(source: String, generation: Int, document: RenderableDocument) {
        let value = MarkdownParseResult(
            source: source,
            generation: generation,
            document: document
        )
        if result != value { result = value }
    }

    private nonisolated static func parse(
        source: String,
        config: MarkdownRenderConfig
    ) async -> RenderableDocument {
        await MarkdownDocumentCache.shared.document(
            for: source,
            config: config,
            store: false
        )
    }
}

/// 对话画布的 Markdown 渲染配置。`MarkdownDocumentCache` 预热时也用 `plain`。
enum AurewaysMarkdown {
    static let body: CGFloat = 13.5
    static let code: CGFloat = 12.5
    static let table: CGFloat = 12.5
    static let chrome: CGFloat = 11

    /// 两个配置各只构造一次。每次求值新建 config 会让库里
    /// `CodeBlockView.onChange(of: config)` 判定不等，白白重跑一次语法高亮。
    static let plain = config.withShouldAnimateText(value: false)
    static let animated = config.withShouldAnimateText(value: true)

    static let bodyFonts = fonts(body)
    static let tableFonts = fonts(table)
    static let chromeFonts = fonts(chrome)
    static let codeFonts = TextFonts(
        normal: mono(code),
        italic: nil,
        bold: NSFont.monospacedSystemFont(ofSize: code, weight: .semibold),
        boldItalic: nil,
        preferredLetterSpacing: nil,
        preferredLineHeight: nil
    )

    static let config: MarkdownRenderConfig = {
        let defaults = MarkdownRenderConfig.default
        return MarkdownRenderConfig(
            shouldAnimateText: false,
            blockQuoteStyle: .init(textFonts: bodyFonts, textColor: .secondary),
            headingStyle: .init(
                h1Font: headingFonts(21),
                h2Font: headingFonts(17.5),
                h3Font: headingFonts(15.5),
                h4Font: headingFonts(14),
                h5Font: headingFonts(13.5),
                h6Font: headingFonts(13.5),
                textColor: .primary
            ),
            orderedListStyle: .init(textFonts: bodyFonts, textColor: .primary),
            paragraphStyle: .init(textFonts: bodyFonts, textColor: .primary),
            tableStyle: .init(
                textFonts: tableFonts,
                headerTextColor: .primary,
                regularTextColor: .primary,
                headerBackgroundColor: Palette.badgeBg,
                borderColor: Palette.border,
                actionButtonColor: Palette.accent
            ),
            inlineStyle: .init(
                boldTextColor: .primary,
                linkTextFont: system(body),
                linkTextColor: Palette.accent,
                linkUnderlineStyle: [],
                codeTextFont: mono(code),
                codeTextColor: .primary,
                codeBackgroundColor: Palette.badgeBg,
                codeUnderlineColor: .clear
            ),
            textContextMenu: defaults.textContextMenu,
            citationConfig: .init(
                font: defaults.citationConfig.font,
                textColor: .secondary,
                backgroundColor: Palette.badgeBg
            ),
            codeBlockConfig: CodeBlockConfig(
                theme: .xcode,
                backgroundColor: Palette.badgeBg,
                foregroundColor: .secondary,
                codeTextFonts: codeFonts,
                chromeTextFonts: chromeFonts
            ),
            blockSpacing: defaults.blockSpacing,
            textSelectionConfig: defaults.textSelectionConfig,
            thematicBreakColor: Palette.border,
            imageConfig: defaults.imageConfig
        )
    }()

    static func headingFonts(_ size: CGFloat) -> TextFonts {
        fonts(size, weight: .semibold)
    }

    static func fonts(_ size: CGFloat, weight: NSFont.Weight = .regular) -> TextFonts {
        TextFonts(
            normal: system(size, weight: weight),
            italic: system(size, weight: weight, italic: true),
            bold: system(size, weight: .semibold),
            boldItalic: system(size, weight: .semibold, italic: true),
            preferredLetterSpacing: nil,
            preferredLineHeight: nil
        )
    }

    static func system(
        _ size: CGFloat,
        weight: NSFont.Weight = .regular,
        italic: Bool = false
    ) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

private struct InspectorResizingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Inspector column is being live-resized. Markdown should keep its last width.
    var inspectorResizing: Bool {
        get { self[InspectorResizingKey.self] }
        set { self[InspectorResizingKey.self] = newValue }
    }
}

/// During inspector split drags, keep the last laid-out width so tables and
/// formulas are not rebuilt every frame. Commit when resizing ends.
struct DebouncedWidth<Content: View>: View {
    @Environment(\.inspectorResizing) private var inspectorResizing
    @ViewBuilder var content: (CGFloat?) -> Content

    @State private var width: CGFloat?
    @State private var latest: CGFloat = 0

    var body: some View {
        content(width)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { _, newWidth in
                guard newWidth > 0 else { return }
                latest = newWidth
                if width == nil || !inspectorResizing {
                    if width == nil || abs((width ?? 0) - newWidth) > 1 {
                        width = newWidth
                    }
                }
            }
            .onChange(of: inspectorResizing) { _, resizing in
                guard !resizing, latest > 0 else { return }
                if width == nil || abs((width ?? 0) - latest) > 1 {
                    width = latest
                }
            }
    }
}
