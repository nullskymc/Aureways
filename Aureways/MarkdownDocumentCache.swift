import Foundation
import SwiftStreamingMarkdown

/// Parsed-markdown cache, keyed by the message source.
///
/// `MarkdownView` parses inside the view: it keeps the controller in a
/// `@StateObject` and parses in `.task(id: text)`. In a virtualized transcript
/// that means two problems. The reparse on every recycle is the cheap one
/// (~0.2 ms per message). The expensive one is that the block renders at height
/// 0 until the parse lands, so a `LazyVStack` measures it as empty and
/// mis-estimates the transcript's extent — which is why the transcript used to
/// fall back to an eager `VStack` for history.
///
/// Holding the parsed `RenderableDocument` outside the view fixes both: a block
/// gets its content synchronously in `init`, so it has its real height the
/// moment it is placed. `DocumentView` renders an already-parsed document, so
/// the library supports this directly.
///
/// Colors are safe to cache across a light/dark switch: the library builds its
/// attributed strings with dynamic `NSColor`s (`Color.dynamic(light:dark:)`),
/// which resolve per draw rather than at build time.
@MainActor
final class MarkdownDocumentCache {
    static let shared = MarkdownDocumentCache()

    private var documents: [String: RenderableDocument] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: Set<String> = []
    private var cachedBytes = 0
    private var warmTask: Task<Void, Never>?

    /// Bounded by source size rather than entry count: a handful of very long
    /// messages should not be able to pin an unbounded amount of memory. A
    /// 300-message transcript is well under this, so it never evicts in practice.
    private let byteLimit = 8 << 20

    private init() {}

    /// The library's parser is a plain, non-`Sendable` class, so it cannot be
    /// stored on a main-actor cache and then used from a background task. It is
    /// created and consumed inside this one nonisolated function instead, which
    /// keeps the parse off the main thread; the initialiser only allocates a few
    /// rewriters, which is nothing next to the ~0.2 ms parse itself.
    private nonisolated static func parse(
        _ source: String,
        config: MarkdownRenderConfig
    ) async -> RenderableDocument {
        await MarkdownParserImpl().parse(text: source, config: config)
    }

    /// The parsed document for `source` if it is already cached. Cheap enough to
    /// call from a view's `init`.
    func cached(_ source: String) -> RenderableDocument? {
        documents[source]
    }

    /// Parses `source` off the main actor and returns the result, storing it
    /// unless `store` is false. Streaming messages pass `store: false`: their
    /// intermediate states are never revisited and would only evict useful
    /// entries.
    func document(
        for source: String,
        config: MarkdownRenderConfig,
        store: Bool = true
    ) async -> RenderableDocument {
        if let hit = documents[source] { return hit }
        let document = await Self.parse(source, config: config)
        if store { insert(source, document) }
        return document
    }

    /// Parses anything not already cached, in the background, one message at a
    /// time. Called when a session is opened and when a turn finishes, so blocks
    /// have their real height before they are ever placed.
    func warm(_ sources: [String], config: MarkdownRenderConfig) {
        let pending = sources.filter { documents[$0] == nil && !inFlight.contains($0) }
        guard !pending.isEmpty else { return }
        inFlight.formUnion(pending)
        let previous = warmTask
        warmTask = Task { [weak self] in
            await previous?.value
            for source in pending {
                if Task.isCancelled { break }
                guard let self else { return }
                let document = await Self.parse(source, config: config)
                self.insert(source, document)
                self.inFlight.remove(source)
            }
            self?.inFlight.subtract(pending)
        }
    }

    #if DEBUG
    /// Entry count and the size of the sources behind them. Bounds how much of
    /// the process footprint this cache can be responsible for.
    var debugFootprint: (entries: Int, sourceKB: Int) {
        (documents.count, cachedBytes / 1024)
    }
    #endif

    private func insert(_ source: String, _ document: RenderableDocument) {
        guard documents.updateValue(document, forKey: source) == nil else { return }
        insertionOrder.append(source)
        cachedBytes += source.utf8.count
        while cachedBytes > byteLimit, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            documents.removeValue(forKey: oldest)
            cachedBytes -= oldest.utf8.count
        }
    }
}
