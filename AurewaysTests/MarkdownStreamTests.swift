import AppKit
import XCTest
import SwiftStreamingMarkdown
@testable import SwiftStreamingMarkdown
@testable import Aureways

/// Streaming markdown used to parse every token and write cancelled results
/// back onto the view. These tests lock the single-flight "latest snapshot wins"
/// behaviour and the latex-document equality that stops formulas being rebuilt.
@MainActor
final class MarkdownStreamTests: XCTestCase {

    override func setUp() async throws {
        MarkdownDocumentCache.shared.removeAllForTests()
    }

    func testReparsingTheSameInlineLatexYieldsAnEqualDocument() async {
        let source = #"Energy is \(E = mc^2\) in this frame."#
        let first = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        let second = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        XCTAssertEqual(first, second)
    }

    func testReparsingTheSameBlockLatexYieldsAnEqualDocument() async {
        let source = """
        The identity:

        $$a^2 + b^2 = c^2$$

        holds in the plane.
        """
        let first = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        let second = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        XCTAssertEqual(first, second)
    }

    func testStreamParserSettlesOnTheLatestSnapshot() async {
        let gate = MarkdownParseGate()
        let parser = MarkdownStreamParser(parse: gate.parse)
        let snapshots = [
            #"Let \(a = 1\)"#,
            #"Let \(a = 1\) and \(b = 2\)"#,
            #"Let \(a = 1\) and \(b = 2\) hold."#
        ]

        parser.request(source: snapshots[0], config: AurewaysMarkdown.plain, store: false)
        await gate.waitUntilStarted(snapshots[0])
        parser.request(source: snapshots[1], config: AurewaysMarkdown.plain, store: false)
        parser.request(source: snapshots[2], config: AurewaysMarkdown.plain, store: false)

        await gate.release(snapshots[0])
        await gate.waitUntilStarted(snapshots[2])
        XCTAssertNil(parser.result)
        await gate.release(snapshots[2])
        await parser.waitUntilIdle()

        let startedSources = await gate.startedSources()
        XCTAssertEqual(parser.result?.source, snapshots[2])
        XCTAssertEqual(startedSources, [snapshots[0], snapshots[2]])
    }

    func testClosedInlineLatexKeepsTextStorageAcrossStreamingChunks() async {
        let stem = #"The energy \(E = mc^2\) "#
        let snapshots = [
            stem,
            stem + "is conserved.",
            stem + "is conserved in this system.",
            stem + "is conserved in this system even after many more tokens."
        ]
        let view = ParagraphNSView()
        var storageID: ObjectIdentifier?

        for source in snapshots {
            let document = await MarkdownDocumentCache.shared.document(
                for: source,
                config: AurewaysMarkdown.plain,
                store: false
            )
            guard case .paragraph(_, let content) = document.renderables.first else {
                return XCTFail("expected a paragraph for \(source)")
            }
            view.setParagraphContents(content, animatedByWord: false)
            guard let storage = view.textStorage else {
                return XCTFail("text storage missing")
            }
            if let storageID {
                XCTAssertEqual(
                    ObjectIdentifier(storage),
                    storageID,
                    "replacing the storage rebuilds every latex attachment view"
                )
            } else {
                storageID = ObjectIdentifier(storage)
            }
        }
        XCTAssertGreaterThan(view.textStorage?.length ?? 0, stem.count)
    }

    func testChatSessionChunksDriveParserToTheFinalLatexSnapshot() async {
        let session = ChatSession(
            agent: AgentProfile(
                id: "test",
                title: "Test",
                subtitle: "",
                command: "/usr/bin/true",
                arguments: [],
                builtIn: false,
                notes: ""
            ),
            cwd: "/tmp"
        )
        let tokens = [
            "The energy ",
            "\\(E = mc^2\\)",
            " is conserved",
            " in this frame."
        ]
        for token in tokens {
            session.apply(SessionNotification(
                sessionId: "s",
                update: .agentMessageChunk(.text(token))
            ))
        }

        guard case .agent(_, let markdown) = session.items.last else {
            return XCTFail("expected an agent message")
        }
        XCTAssertEqual(markdown, tokens.joined())

        let parser = MarkdownStreamParser()
        var growing = ""
        var generation = 0
        for token in tokens {
            growing += token
            generation = parser.request(
                source: growing,
                config: AurewaysMarkdown.plain,
                store: false
            )
        }

        await parser.waitUntilIdle()
        XCTAssertEqual(parser.result?.source, markdown)
        XCTAssertEqual(parser.result?.generation, generation)
    }

    func testCancelDropsResultAndRequestAfterCancelRestartsPump() async {
        let gate = MarkdownParseGate()
        let parser = MarkdownStreamParser(parse: gate.parse)

        parser.request(source: "cancelled", config: AurewaysMarkdown.plain, store: true)
        await gate.waitUntilStarted("cancelled")
        parser.cancel()
        await gate.release("cancelled")
        await parser.waitUntilIdle()

        XCTAssertNil(parser.result)
        XCTAssertNil(MarkdownDocumentCache.shared.cached("cancelled"))

        parser.request(source: "restarted", config: AurewaysMarkdown.plain, store: true)
        await gate.waitUntilStarted("restarted")
        await gate.release("restarted")
        await parser.waitUntilIdle()

        let maximumConcurrentParses = await gate.maximumConcurrentParses()
        XCTAssertEqual(parser.result?.source, "restarted")
        XCTAssertNotNil(MarkdownDocumentCache.shared.cached("restarted"))
        XCTAssertEqual(maximumConcurrentParses, 1)
    }

    func testFinalRequestStoresOnlyItsSource() async {
        let gate = MarkdownParseGate()
        let parser = MarkdownStreamParser(parse: gate.parse)

        parser.request(source: "draft", config: AurewaysMarkdown.plain, store: false)
        await gate.waitUntilStarted("draft")
        parser.request(source: "final", config: AurewaysMarkdown.plain, store: true)
        await gate.release("draft")
        await gate.waitUntilStarted("final")
        await gate.release("final")
        await parser.waitUntilIdle()

        XCTAssertNil(MarkdownDocumentCache.shared.cached("draft"))
        XCTAssertNotNil(MarkdownDocumentCache.shared.cached("final"))
    }

    func testDuplicateStoreDoesNotReplaceFirstDocumentOrBookkeeping() async {
        let source = "duplicate"
        let first = await MarkdownDocumentCache.shared.document(
            for: "first",
            config: AurewaysMarkdown.plain,
            store: false
        )
        let second = await MarkdownDocumentCache.shared.document(
            for: "second",
            config: AurewaysMarkdown.plain,
            store: false
        )

        MarkdownDocumentCache.shared.store(source, first)
        let footprint = MarkdownDocumentCache.shared.debugFootprint
        MarkdownDocumentCache.shared.store(source, second)

        XCTAssertEqual(MarkdownDocumentCache.shared.cached(source), first)
        XCTAssertEqual(MarkdownDocumentCache.shared.debugFootprint.entries, footprint.entries)
        XCTAssertEqual(MarkdownDocumentCache.shared.debugFootprint.sourceKB, footprint.sourceKB)
    }

    func testCacheStoresFinalDocumentAsOneSelectableTextBlock() async {
        let source = """
        # Heading

        First paragraph.

        - First item
        - Second item

        Last paragraph.
        """
        let parsed = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        let stored = MarkdownDocumentCache.shared.store(source, parsed)

        XCTAssertEqual(stored.renderables.count, 1)
        guard case .paragraph(_, let content) = stored.renderables.first else {
            return XCTFail("expected one selectable text block")
        }
        XCTAssertEqual(
            content.string,
            "Heading\n\nFirst paragraph.\n\n•  First item\n•  Second item\n\nLast paragraph."
        )
        XCTAssertEqual(MarkdownDocumentCache.shared.cached(source), stored)
    }

    func testCacheStoresNestedListsAndQuotesAsOneSelectableTextBlock() async {
        let source = """
        # Plan

        1. First step:
           - Sub-step A
           - Sub-step B
        2. Second step

        > Important notice

        ---

        Final conclusion.
        """
        let parsed = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        let stored = MarkdownDocumentCache.shared.store(source, parsed)

        XCTAssertEqual(stored.renderables.count, 1)
        guard case .paragraph(_, let content) = stored.renderables.first else {
            return XCTFail("expected one selectable text block")
        }
        XCTAssertTrue(content.string.contains("Plan"))
        XCTAssertTrue(content.string.contains("1.  First step:"))
        XCTAssertTrue(content.string.contains("Sub-step A"))
        XCTAssertTrue(content.string.contains("2.  Second step"))
        XCTAssertTrue(content.string.contains("Important notice"))
        XCTAssertTrue(content.string.contains("Final conclusion."))
    }

    func testStoreMakesTheNextReadACacheHit() async {
        let source = #"Cached \(x^2\) formula."#
        let parsed = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        XCTAssertNil(MarkdownDocumentCache.shared.cached(source))
        MarkdownDocumentCache.shared.store(source, parsed)
        XCTAssertEqual(MarkdownDocumentCache.shared.cached(source), parsed)
    }

    func testInlineDollarMathBecomesALatexAttachment() async {
        let source = #"Let $f_\beta(x)$ and $\theta$ hold."#
        let document = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        guard case .paragraph(_, let content) = document.renderables.first else {
            return XCTFail("expected a paragraph")
        }
        let payloads = latexPayloads(in: content)
        XCTAssertEqual(payloads, [#"f_\beta(x)"#, #"\theta"#])
        XCTAssertFalse(content.string.contains("$"))
        XCTAssertFalse(content.string.contains("beta"))
    }

    func testInlineDollarMathInsideTableCells() async {
        let source = """
        | Loss |
        | --- |
        | $\\mathcal{L}(x_t, y_t)$ |
        """
        let document = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        guard case .table(_, _, let rows, _) = document.renderables.first else {
            return XCTFail("expected a table, got \(document.renderables)")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(latexPayloads(in: rows[0][0]), [#"\mathcal{L}(x_t, y_t)"#])
    }

    func testInlineDollarPreprocessorSkipsCurrencyAndFencedCode() {
        let processor = LaTexPreProcessorImpl()
        let source = """
        Price is $5 and $10.

        ```swift
        let money = "$x$"
        ```

        Then $E = mc^2$.
        """
        let processed = processor.process(input: source)
        XCTAssertTrue(processed.contains("$5"))
        XCTAssertTrue(processed.contains("$10"))
        XCTAssertTrue(processed.contains(#"let money = "$x$""#))
        XCTAssertTrue(processed.contains(#"`\(E = mc^2\)`"#))
        XCTAssertFalse(processed.contains("$E = mc^2$"))
    }

    func testSlashBracketInlineMathStillWorksAlongsideDollars() async {
        let source = #"Both \(a + b\) and $c + d$."#
        let document = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        guard case .paragraph(_, let content) = document.renderables.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(latexPayloads(in: content), ["a + b", "c + d"])
    }
}

private func latexPayloads(in attributed: NSAttributedString) -> [String] {
    var payloads: [String] = []
    attributed.enumerateAttribute(
        .attachment,
        in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
        if let attachment = value as? LatexTextAttachment {
            payloads.append(attachment.payload.latex)
        }
    }
    return payloads
}

private actor MarkdownParseGate {
    private var started: [String] = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    private var maxActive = 0

    func parse(
        source: String,
        config: MarkdownRenderConfig
    ) async -> RenderableDocument {
        active += 1
        maxActive = max(maxActive, active)
        started.append(source)
        startWaiters.removeValue(forKey: source)?.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releases[source] = continuation
        }
        active -= 1
        return await MarkdownDocumentCache.shared.document(
            for: source,
            config: config,
            store: false
        )
    }

    func waitUntilStarted(_ source: String) async {
        guard !started.contains(source) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[source, default: []].append(continuation)
        }
    }

    func release(_ source: String) {
        releases.removeValue(forKey: source)?.resume()
    }

    func startedSources() -> [String] { started }
    func maximumConcurrentParses() -> Int { maxActive }
}
