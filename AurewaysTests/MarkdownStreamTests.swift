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
        let parser = MarkdownStreamParser()
        let snapshots = [
            #"Let \(a = 1\)"#,
            #"Let \(a = 1\) and \(b = 2\)"#,
            #"Let \(a = 1\) and \(b = 2\) hold."#
        ]
        for source in snapshots {
            parser.request(source: source, config: AurewaysMarkdown.plain, store: false)
        }

        let last = snapshots.last!
        let deadline = Date().addingTimeInterval(2)
        var settled = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard parser.document != nil else { continue }
            // Re-parse immediately before comparing: NSColor catalog identity
            // is not stable across a long wait, but consecutive parses of the
            // same source are (see the equality tests above).
            let expected = await MarkdownDocumentCache.shared.document(
                for: last,
                config: AurewaysMarkdown.plain,
                store: false
            )
            if parser.document == expected {
                settled = true
                break
            }
        }
        XCTAssertTrue(settled, "parser should publish the latest snapshot")
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
        for token in tokens {
            growing += token
            parser.request(source: growing, config: AurewaysMarkdown.plain, store: false)
        }

        let deadline = Date().addingTimeInterval(2)
        var settled = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard parser.document != nil else { continue }
            let expected = await MarkdownDocumentCache.shared.document(
                for: markdown,
                config: AurewaysMarkdown.plain,
                store: false
            )
            if parser.document == expected {
                settled = true
                break
            }
        }
        XCTAssertTrue(settled)
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
}
