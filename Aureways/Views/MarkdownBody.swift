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

    private var coldPlaceholderText: Substring {
        let prefix = source.prefix(1200)
        let lines = prefix.split(separator: "\n", maxSplits: 25, omittingEmptySubsequences: false)
        if lines.count > 24 {
            let truncated = lines.prefix(24).joined(separator: "\n")
            return prefix.prefix(truncated.count)
        }
        return prefix
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
                // Stable during streaming so paragraph views can append.
                // Flip identity when the turn ends so leftover incremental
                // blocks cannot linger the way they do until a session switch.
                .id(isStreaming ? "streaming" : source)
            } else {
                // 解析落地前用同字号明文占位。高度只是近似，但远好过 0——
                // 高度 0 会让虚拟化的 stack 把这条消息当成不存在。
                // PERF-06: 截断预览，避免数千行文档在冷缓存异步解析完成前造成主线程整篇排版卡顿
                Text(coldPlaceholderText)
                    .font(.system(size: AurewaysMarkdown.body))
                    .foregroundStyle(.primary)
                    .lineLimit(25)
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
            guard let result, result.source == source else { return }
            // While streaming, ignore stale generations. Once the turn ends,
            // accept the matching source even if a later enqueueParse bumped
            // requestedGeneration — otherwise the incremental duplicate stays
            // on screen until the view is recreated (session switch).
            if isStreaming, result.generation != requestedGeneration { return }
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
        requestedGeneration = streamParser.request(
            source: source,
            config: config,
            store: !isStreaming
        )
    }
}


/// Detects safe top-level Markdown block boundaries for incremental streaming parses (PERF-03).
///
/// A candidate is a blank line outside fences / display math. It is only safe
/// when the following non-empty line cannot continue the construct above it
/// (loose lists, indented list continuations, quotes, tables, setext
/// underlines, link reference definitions).
enum MarkdownBlockBoundary {
    static func lastSafeBoundary(in text: String) -> String.Index? {
        guard !text.isEmpty else { return nil }

        var inCodeFence: Character?
        var fenceLength = 0
        var inMathDisplay = false
        var lastSafeIndex: String.Index?
        var openConstructStart: String.Index?
        var previousNonEmpty: Substring?
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let (line, nextLineStart) = nextLine(in: text, from: currentIndex)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingIndent(line)

            if let fenceChar = inCodeFence {
                if indent < 4,
                   trimmed.starts(with: String(repeating: fenceChar, count: fenceLength)) {
                    let remaining = trimmed.drop(while: { $0 == fenceChar })
                        .trimmingCharacters(in: .whitespaces)
                    if remaining.isEmpty {
                        inCodeFence = nil
                        fenceLength = 0
                        openConstructStart = nil
                        previousNonEmpty = line
                    }
                }
            } else if inMathDisplay {
                if trimmed == "$$" || trimmed.hasSuffix("$$") {
                    inMathDisplay = false
                    openConstructStart = nil
                    previousNonEmpty = line
                }
            } else if indent < 4, isFenceOpener(trimmed) {
                let firstChar = trimmed.first!
                inCodeFence = firstChar
                fenceLength = trimmed.prefix(while: { $0 == firstChar }).count
                openConstructStart = currentIndex
                previousNonEmpty = line
            } else if indent < 4, isMathOpener(trimmed) {
                if isSingleLineDisplayMath(trimmed) {
                    previousNonEmpty = line
                } else {
                    inMathDisplay = true
                    openConstructStart = currentIndex
                    previousNonEmpty = line
                }
            } else if trimmed.isEmpty {
                if let previous = previousNonEmpty,
                   let next = nextNonEmptyLine(in: text, from: nextLineStart),
                   isSafeBlockBreak(previous: previous, next: next) {
                    lastSafeIndex = nextLineStart
                }
            } else {
                previousNonEmpty = line
            }

            currentIndex = nextLineStart
        }

        if inCodeFence != nil || inMathDisplay {
            return openConstructStart
        }
        return lastSafeIndex
    }

    /// Unclosed fenced code from `start` through EOF. `start` must be the
    /// opener line. Returns nil when this is not a fence or the fence closed.
    static func unclosedFence(
        in source: String,
        from start: String.Index
    ) -> (language: String?, code: String)? {
        guard start < source.endIndex else { return nil }
        let (line, bodyStart) = nextLine(in: source, from: start)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard leadingIndent(line) < 4, isFenceOpener(trimmed) else { return nil }
        let firstChar = trimmed.first!
        let fenceLength = trimmed.prefix(while: { $0 == firstChar }).count
        let language = fenceLanguage(trimmed)

        var current = bodyStart
        while current < source.endIndex {
            let (bodyLine, next) = nextLine(in: source, from: current)
            let bodyTrimmed = bodyLine.trimmingCharacters(in: .whitespaces)
            if leadingIndent(bodyLine) < 4,
               bodyTrimmed.starts(with: String(repeating: firstChar, count: fenceLength)) {
                let remaining = bodyTrimmed.drop(while: { $0 == firstChar })
                    .trimmingCharacters(in: .whitespaces)
                if remaining.isEmpty {
                    return nil
                }
            }
            current = next
        }
        return (language, String(source[bodyStart...]))
    }

    private static func fenceLanguage(_ opener: String) -> String? {
        guard let first = opener.first else { return nil }
        let rest = opener.drop(while: { $0 == first }).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return rest.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func nextLine(
        in text: String,
        from start: String.Index
    ) -> (Substring, String.Index) {
        var lineEnd = start
        while lineEnd < text.endIndex && text[lineEnd] != "\n" && text[lineEnd] != "\r" {
            lineEnd = text.index(after: lineEnd)
        }
        return (text[start..<lineEnd], skipNewline(in: text, from: lineEnd))
    }

    private static func skipNewline(in text: String, from index: String.Index) -> String.Index {
        var next = index
        if next < text.endIndex && text[next] == "\r" {
            next = text.index(after: next)
        }
        if next < text.endIndex && text[next] == "\n" {
            next = text.index(after: next)
        }
        return next
    }

    private static func nextNonEmptyLine(in text: String, from start: String.Index) -> Substring? {
        var index = start
        while index < text.endIndex {
            let (line, next) = nextLine(in: text, from: index)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return line
            }
            if next == index { break }
            index = next
        }
        return nil
    }

    private static func isSafeBlockBreak(previous: Substring, next: Substring) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespaces)
        let nxt = next.trimmingCharacters(in: .whitespaces)
        let nextIndent = leadingIndent(next)
        let prevIndent = leadingIndent(previous)

        if nextIndent >= 4 { return false }
        if isSetextUnderline(nxt) { return false }
        if isLinkReferenceDefinition(nxt) { return false }

        if isListMarker(nxt) {
            return !isListMarker(prev) && prevIndent < 4 && !prev.hasPrefix(">")
        }
        if nxt.hasPrefix("|") {
            return !prev.hasPrefix("|")
        }
        if nxt.hasPrefix(">") {
            return !prev.hasPrefix(">")
        }
        return true
    }

    private static func leadingIndent(_ line: Substring) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private static func isFenceOpener(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isMathOpener(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("$$")
    }

    private static func isSingleLineDisplayMath(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4
    }

    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == "=" } || trimmed.allSatisfy { $0 == "-" }
    }

    private static func isListMarker(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        var index = trimmed.startIndex
        var digits = 0
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits += 1
            if digits > 9 { return false }
            index = trimmed.index(after: index)
        }
        guard digits > 0, index < trimmed.endIndex else { return false }
        let marker = trimmed[index]
        guard marker == "." || marker == ")" else { return false }
        let after = trimmed.index(after: index)
        return after == trimmed.endIndex || trimmed[after].isWhitespace
    }

    private static func isLinkReferenceDefinition(_ trimmed: String) -> Bool {
        guard trimmed.first == "[" else { return false }
        guard let close = trimmed.firstIndex(of: "]") else { return false }
        let after = trimmed.index(after: close)
        return after < trimmed.endIndex && trimmed[after] == ":"
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

    // Incremental streaming parse state (PERF-03)
    private var committedSource: String = ""
    private var committedDocument: RenderableDocument?

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
        resetCommitted()
        pumpTask?.cancel()
        return generation
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        let parse = parse
        pumpTask = Task { [weak self] in
            while let work = self?.takeLatest() {
                guard let self else { return }
                let outcome = await self.parseWork(work, parse: parse)
                if Task.isCancelled { break }
                guard work.generation == self.generation,
                      self.latest == nil
                else { continue }
                self.committedSource = outcome.committedSource
                self.committedDocument = outcome.committedDocument
                let publishedDocument: RenderableDocument
                if work.store {
                    publishedDocument = MarkdownDocumentCache.shared.store(work.source, outcome.display)
                    self.resetCommitted()
                } else {
                    publishedDocument = outcome.display
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

    private struct ParseOutcome {
        var display: RenderableDocument
        var committedSource: String
        var committedDocument: RenderableDocument?
    }

    /// Pure with respect to parser state: a discarded in-flight snapshot must
    /// not append into `committedDocument`. The pump applies the outcome only
    /// when this work is still the latest generation.
    private func parseWork(
        _ work: Work,
        parse: Parse
    ) async -> ParseOutcome {
        if work.store {
            let document = await parse(work.source, work.config)
            return ParseOutcome(display: document, committedSource: "", committedDocument: nil)
        }

        var committedSource = self.committedSource
        var committedDocument = self.committedDocument

        if !committedSource.isEmpty && !work.source.starts(with: committedSource) {
            committedSource = ""
            committedDocument = nil
        }

        guard let boundary = MarkdownBlockBoundary.lastSafeBoundary(in: work.source) else {
            let document = await parse(work.source, work.config)
            return ParseOutcome(display: document, committedSource: "", committedDocument: nil)
        }

        let prefix = work.source[..<boundary]

        if prefix.isEmpty {
            let tailDoc = await parseTail(work.source, from: boundary, config: work.config, parse: parse)
            return ParseOutcome(display: tailDoc, committedSource: "", committedDocument: nil)
        }

        if let committed = committedDocument,
           !committedSource.isEmpty,
           prefix == committedSource {
            let tailDoc = await parseTail(work.source, from: boundary, config: work.config, parse: parse)
            return ParseOutcome(
                display: committed.appending(tailDoc),
                committedSource: committedSource,
                committedDocument: committed
            )
        }

        if let committed = committedDocument,
           !committedSource.isEmpty,
           prefix.starts(with: committedSource) {
            let newSlice = prefix.dropFirst(committedSource.count)
            if newSlice.isEmpty {
                let tailDoc = await parseTail(work.source, from: boundary, config: work.config, parse: parse)
                return ParseOutcome(
                    display: committed.appending(tailDoc),
                    committedSource: committedSource,
                    committedDocument: committed
                )
            }
            let sliceDoc = await parse(String(newSlice), work.config)
            let updatedCommitted = committed.appending(sliceDoc)
            let tailDoc = await parseTail(work.source, from: boundary, config: work.config, parse: parse)
            return ParseOutcome(
                display: updatedCommitted.appending(tailDoc),
                committedSource: String(prefix),
                committedDocument: updatedCommitted
            )
        }

        let prefixDoc = await parse(String(prefix), work.config)
        let tailDoc = await parseTail(work.source, from: boundary, config: work.config, parse: parse)
        return ParseOutcome(
            display: prefixDoc.appending(tailDoc),
            committedSource: String(prefix),
            committedDocument: prefixDoc
        )
    }

    private func parseTail(
        _ source: String,
        from start: String.Index,
        config: MarkdownRenderConfig,
        parse: Parse
    ) async -> RenderableDocument {
        if start >= source.endIndex {
            return .empty
        }
        if let fence = MarkdownBlockBoundary.unclosedFence(in: source, from: start) {
            return .synthesizedCodeBlock(language: fence.language, code: fence.code)
        }
        return await parse(String(source[start...]), config)
    }

    private func resetCommitted() {
        committedSource = ""
        committedDocument = nil
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
