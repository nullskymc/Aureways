import AppKit
import SwiftUI
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

    func testMarkdownBlockBoundaryDetectsCodeFencesAndMath() {
        let fenced = """
        Intro paragraph.

        ```swift
        let a = 1

        let b = 2
        ```

        After the fence.
        """
        let fenceBoundary = MarkdownBlockBoundary.lastSafeBoundary(in: fenced)
        XCTAssertNotNil(fenceBoundary)
        if let index = fenceBoundary {
            XCTAssertTrue(String(fenced[index...]).hasPrefix("After the fence."))
            let prefix = String(fenced[..<index])
            XCTAssertTrue(prefix.contains("let a = 1"))
            XCTAssertTrue(prefix.contains("let b = 2"))
            XCTAssertFalse(prefix.contains("After the fence"))
        }

        let math = """
        Intro paragraph.

        $$
        a + b

        = c
        $$

        After math.
        """
        let mathBoundary = MarkdownBlockBoundary.lastSafeBoundary(in: math)
        XCTAssertNotNil(mathBoundary)
        if let index = mathBoundary {
            XCTAssertTrue(String(math[index...]).hasPrefix("After math."))
            let prefix = String(math[..<index])
            XCTAssertTrue(prefix.contains("a + b"))
            XCTAssertTrue(prefix.contains("= c"))
            XCTAssertFalse(prefix.contains("After math"))
        }
    }

    func testMarkdownBlockBoundaryDoesNotSplitLooseLists() {
        let loose = """
        1. First.

        2. Second.
        """
        XCTAssertNil(MarkdownBlockBoundary.lastSafeBoundary(in: loose))

        let afterList = """
        Intro paragraph.

        1. First.

        2. Second.

        Closing paragraph.
        """
        let boundary = MarkdownBlockBoundary.lastSafeBoundary(in: afterList)
        XCTAssertNotNil(boundary)
        if let index = boundary {
            XCTAssertTrue(String(afterList[index...]).hasPrefix("Closing paragraph."))
            let prefix = String(afterList[..<index])
            XCTAssertTrue(prefix.contains("Intro paragraph."))
            XCTAssertTrue(prefix.contains("1. First."))
            XCTAssertTrue(prefix.contains("2. Second."))
        }

        let paraThenList = """
        Intro paragraph.

        1. First item growing
        """
        let listStart = MarkdownBlockBoundary.lastSafeBoundary(in: paraThenList)
        XCTAssertNotNil(listStart)
        if let index = listStart {
            XCTAssertTrue(String(paraThenList[index...]).hasPrefix("1. First item"))
            XCTAssertFalse(String(paraThenList[..<index]).contains("1. First"))
        }
    }

    func testAppendingRekeysTailIDs() async {
        let prefix = await MarkdownDocumentCache.shared.document(
            for: "Hello world.\n\n",
            config: AurewaysMarkdown.plain,
            store: false
        )
        let tail = await MarkdownDocumentCache.shared.document(
            for: "Second paragraph.",
            config: AurewaysMarkdown.plain,
            store: false
        )
        XCTAssertFalse(prefix.renderables.isEmpty)
        XCTAssertFalse(tail.renderables.isEmpty)
        let combined = prefix.appending(tail)
        let ids = combined.renderables.map(\.id)
        XCTAssertEqual(ids.count, prefix.renderables.count + tail.renderables.count)
        XCTAssertEqual(ids.count, Set(ids).count, "concatenated documents must not reuse cmark ids")
        XCTAssertEqual(
            prefix.renderables.map(\.id),
            Array(ids.prefix(prefix.renderables.count))
        )
    }

    func testMarkdownStreamParserIncrementalParsingReusesCommittedBlocks() async throws {
        let parser = MarkdownStreamParser()
        let snapshots = [
            "Hello world.\n\nSecond",
            "Hello world.\n\nSecond paragraph grows.",
            "Hello world.\n\nSecond paragraph grows.\n\nThird."
        ]
        var committedID: String?
        for source in snapshots {
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
            await parser.waitUntilIdle()
            let document = try XCTUnwrap(parser.result?.document)
            let ids = document.renderables.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count)
            let firstID = try XCTUnwrap(ids.first)
            if let committedID {
                XCTAssertEqual(firstID, committedID)
            } else {
                committedID = firstID
            }
        }

        let incremental = try XCTUnwrap(parser.result?.document)
        let full = await MarkdownDocumentCache.shared.document(
            for: snapshots.last!,
            config: AurewaysMarkdown.plain,
            store: false
        )
        XCTAssertEqual(incremental.plainText, full.plainText)
    }

    func testIncrementalLooseListKeepsSingleOrderedList() async throws {
        let source = """
        Intro paragraph.

        1. First.

        2. Second.

        Closing paragraph.
        """
        let parser = MarkdownStreamParser()
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()
        let document = try XCTUnwrap(parser.result?.document)
        let listCounts = document.renderables.compactMap { renderable -> Int? in
            if case .orderedList(_, let items) = renderable { return items.count }
            return nil
        }
        XCTAssertEqual(listCounts, [2], "loose list must parse as one list, not two 1-item lists")
        let ids = document.renderables.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testStoreTrueFullParseMatchesMergedDocument() async throws {
        let source = """
        Intro paragraph.

        1. First.

        2. Second.

        Closing paragraph.
        """
        let control = await MarkdownDocumentCache.shared.document(
            for: source,
            config: AurewaysMarkdown.plain,
            store: false
        )
        MarkdownDocumentCache.shared.removeAllForTests()

        let parser = MarkdownStreamParser()
        parser.request(
            source: "Intro paragraph.\n\n1. First.",
            config: AurewaysMarkdown.plain,
            store: false
        )
        parser.request(source: source, config: AurewaysMarkdown.plain, store: true)
        await parser.waitUntilIdle()

        let stored = try XCTUnwrap(MarkdownDocumentCache.shared.cached(source))
        XCTAssertEqual(stored.plainText, control.mergingAdjacentTextBlocks.plainText)
    }

    func testStreamingClosedParagraphIsNotDuplicated() async throws {
        let p1 = "它不会造成分栏拖动卡顿、长回答越来越贵、滚动掉帧——那些是 PERF-03/04/09 的事，而且合帧本身是在保护主线程。"
        let p2 = "有影响，但和前面那批前端 PERF 不是一类问题。"
        let parser = MarkdownStreamParser()
        var source = p1
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()

        source += "\n\n"
        for character in p2 {
            source.append(character)
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
            await parser.waitUntilIdle()
        }
        source += "\n\n下一段开始"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()

        let text = try XCTUnwrap(parser.result?.document.plainText)
        let copies = text.components(separatedBy: p2).count - 1
        XCTAssertEqual(copies, 1, "closed paragraph duplicated \(copies) times in:\n\(text)")
        XCTAssertEqual(
            try XCTUnwrap(parser.result?.document.renderables.map(\.id).count),
            Set(parser.result?.document.renderables.map(\.id) ?? []).count
        )
    }

    func testBurstStreamingClosedParagraphIsNotDuplicated() async throws {
        let p1 = "第一段已经写完。"
        let p2 = "有影响，但和前面那批前端 PERF 不是一类问题。"
        let parser = MarkdownStreamParser()
        var source = p1 + "\n\n"
        for character in p2 {
            source.append(character)
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        }
        source += "\n\n"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        source += "下一段"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()

        let text = try XCTUnwrap(parser.result?.document.plainText)
        let copies = text.components(separatedBy: p2).count - 1
        XCTAssertEqual(copies, 1, "burst streaming duplicated paragraph \(copies) times in:\n\(text)")
    }

    func testAgentSnapshotChunksDoNotDuplicateParagraphs() {
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
        let p1 = "它不会造成分栏拖动卡顿。"
        let p2 = "有影响，但和前面那批前端 PERF 不是一类问题。"
        let snapshots = [
            p1,
            p1 + "\n\n" + p2,
            p1 + "\n\n" + p2,
            p1 + "\n\n" + p2,
            p1 + "\n\n" + p2,
            p1 + "\n\n" + p2
        ]
        for snapshot in snapshots {
            session.apply(SessionNotification(
                sessionId: "s",
                update: .agentMessageChunk(.text(snapshot))
            ))
        }
        guard case .agent(_, let markdown) = session.items.last else {
            return XCTFail("expected an agent message")
        }
        XCTAssertEqual(markdown, p1 + "\n\n" + p2)
        XCTAssertEqual(markdown.components(separatedBy: p2).count - 1, 1)
    }

    func testDiscardedInFlightParseDoesNotDuplicateCommittedBlocks() async throws {
        let parser = MarkdownStreamParser { source, config in
            try? await Task.sleep(nanoseconds: 15_000_000)
            return await MarkdownDocumentCache.shared.document(
                for: source,
                config: config,
                store: false
            )
        }
        let p1 = "两次提交"
        let p2 = "c79c11c 引入遮罩，顺带修了拖动崩溃。"
        let p3 = "拖动状态从三个 State 换成 SplitResizeEngine。"
        var source = "## \(p1)\n\n"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        for character in p2 {
            source.append(character)
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        }
        source += "\n\n"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        for character in p3 {
            source.append(character)
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        }
        source += "\n\n收尾。"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        parser.request(source: source, config: AurewaysMarkdown.plain, store: true)
        await parser.waitUntilIdle()

        let text = try XCTUnwrap(parser.result?.document.plainText)
        XCTAssertEqual(text.components(separatedBy: p1).count - 1, 1, "heading duplicated in:\n\(text)")
        XCTAssertEqual(text.components(separatedBy: p2).count - 1, 1, "paragraph duplicated in:\n\(text)")
        let ids = try XCTUnwrap(parser.result?.document.renderables.map(\.id))
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAgentDeltaChunksStillConcatenate() {
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
        for token in ["有影响，", "但和前面", "那批前端 PERF 不是一类问题。"] {
            session.apply(SessionNotification(
                sessionId: "s",
                update: .agentMessageChunk(.text(token))
            ))
        }
        guard case .agent(_, let markdown) = session.items.last else {
            return XCTFail("expected an agent message")
        }
        XCTAssertEqual(markdown, "有影响，但和前面那批前端 PERF 不是一类问题。")
    }

    func testUnclosedFenceAtStartIsACommitBoundary() {
        let source = "```swift\nlet a = 1"
        XCTAssertEqual(MarkdownBlockBoundary.lastSafeBoundary(in: source), source.startIndex)
        let fence = MarkdownBlockBoundary.unclosedFence(in: source, from: source.startIndex)
        XCTAssertEqual(fence?.language, "swift")
        XCTAssertEqual(fence?.code, "let a = 1")
        XCTAssertNil(MarkdownBlockBoundary.unclosedFence(in: source + "\n```", from: source.startIndex))
    }

    func testUnclosedFenceAfterIntroDoesNotReparsePrefix() async throws {
        final class ParseLog: @unchecked Sendable {
            private let lock = NSLock()
            private var _sources: [String] = []
            func append(_ source: String) {
                lock.lock()
                _sources.append(source)
                lock.unlock()
            }
            var sources: [String] {
                lock.lock()
                defer { lock.unlock() }
                return _sources
            }
        }

        let log = ParseLog()
        let parser = MarkdownStreamParser { source, config in
            log.append(source)
            return await MarkdownDocumentCache.shared.document(
                for: source,
                config: config,
                store: false
            )
        }
        let intro = "Hello world.\n\n"
        var source = intro + "```swift\nlet a"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()
        XCTAssertEqual(log.sources, [intro])
        let first = try XCTUnwrap(parser.result?.document.renderables.first)
        let firstID = first.id
        guard case .codeBlock(_, let language, let code) = parser.result?.document.renderables.last else {
            return XCTFail("expected synthesized code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("let a"))

        source += " = 1"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()
        XCTAssertEqual(log.sources, [intro], "growing unclosed fence must not reparse the committed prefix")
        XCTAssertEqual(parser.result?.document.renderables.first?.id, firstID)
        guard case .codeBlock(_, _, let grown) = parser.result?.document.renderables.last else {
            return XCTFail("expected synthesized code block")
        }
        XCTAssertTrue(grown.contains("let a = 1"))
    }

    func testUnclosedFenceFromDocumentStartSkipsCmark() async throws {
        final class ParseLog: @unchecked Sendable {
            private let lock = NSLock()
            private var _sources: [String] = []
            func append(_ source: String) {
                lock.lock()
                _sources.append(source)
                lock.unlock()
            }
            var sources: [String] {
                lock.lock()
                defer { lock.unlock() }
                return _sources
            }
        }

        let log = ParseLog()
        let parser = MarkdownStreamParser { source, config in
            log.append(source)
            return await MarkdownDocumentCache.shared.document(
                for: source,
                config: config,
                store: false
            )
        }
        parser.request(source: "```swift\nlet a", config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()
        XCTAssertTrue(log.sources.isEmpty)
        let firstID = try XCTUnwrap(parser.result?.document.renderables.first?.id)
        parser.request(source: "```swift\nlet a = 1", config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()
        XCTAssertTrue(log.sources.isEmpty)
        XCTAssertEqual(parser.result?.document.renderables.first?.id, firstID)
        guard case .codeBlock(_, let language, let code) = parser.result?.document.renderables.first else {
            return XCTFail("expected synthesized code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1")
    }

    func testClosingFenceReturnsToCmarkAndDropsSyntheticID() async throws {
        let parser = MarkdownStreamParser()
        let intro = "Hello world.\n\n"
        parser.request(
            source: intro + "```swift\nlet a = 1",
            config: AurewaysMarkdown.plain,
            store: false
        )
        await parser.waitUntilIdle()
        parser.request(
            source: intro + "```swift\nlet a = 1\n```\n\nAfter the fence.",
            config: AurewaysMarkdown.plain,
            store: false
        )
        await parser.waitUntilIdle()
        let ids = try XCTUnwrap(parser.result?.document.renderables.map(\.id))
        XCTAssertFalse(ids.contains { $0.contains("open-fence") })
        let text = try XCTUnwrap(parser.result?.document.plainText)
        XCTAssertTrue(text.contains("Hello world."))
        XCTAssertTrue(text.contains("let a = 1"))
        XCTAssertTrue(text.contains("After the fence."))
    }

    func testOpenFenceStreamingCurveDoesNotParsePrefix() async {
        print("\n=== PERF_CURVE OPEN_FENCE_STREAM ===")
        final class ParseLog: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func add() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let log = ParseLog()
        let parser = MarkdownStreamParser { source, config in
            log.add()
            return await MarkdownDocumentCache.shared.document(
                for: source,
                config: config,
                store: false
            )
        }
        var source = "Intro paragraph.\n\n```swift\n"
        parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        await parser.waitUntilIdle()
        let afterIntro = log.value
        let ticks = 80
        let t0 = DispatchTime.now().uptimeNanoseconds
        for index in 0..<ticks {
            source += "let value\(index) = \(index)\n"
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
            await parser.waitUntilIdle()
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let avgMs = Double(t1 - t0) / Double(ticks) / 1_000_000
        print(String(
            format: "PERF_CURVE ticks=%d prefix_parses=%d extra_parses=%d avg_tick=%7.4fms",
            ticks,
            afterIntro,
            log.value - afterIntro,
            avgMs
        ))
        XCTAssertEqual(log.value, afterIntro, "open fence growth must not reparse committed prefix")
    }

    func testTableWidthHostDoesNotReportProposedWidth() {
        final class MeasuredSize {
            var value: CGSize = .zero
        }
        struct SizeProbe: Layout {
            var box: MeasuredSize
            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                let child = subviews[0].sizeThatFits(proposal)
                box.value = child
                return CGSize(width: proposal.width ?? child.width, height: proposal.height ?? child.height)
            }
            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
                subviews[0].place(at: bounds.origin, proposal: proposal)
            }
        }
        let box = MeasuredSize()
        let hosting = NSHostingView(rootView: SizeProbe(box: box) {
            TableWidthHost {
                Color.clear.frame(width: 120, height: 16)
            }
        }.frame(width: 800, height: 100))
        hosting.setFrameSize(NSSize(width: 800, height: 100))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            box.value.width,
            120,
            accuracy: 1,
            "reporting the bubble width as the table size leaks into NavigationSplitView"
        )
        XCTAssertEqual(box.value.height, 16, accuracy: 1)
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
