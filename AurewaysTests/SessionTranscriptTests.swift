import AppKit
import XCTest
@testable import Aureways

/// Session/transcript model behaviour the web shell relies on, plus composer
/// paste handling (moved here from the removed SwiftUI view tests).
@MainActor
final class SessionTranscriptTests: XCTestCase {
    static let perfProfile = AgentProfile(
        id: "perf", title: "Perf", subtitle: "", command: "true",
        arguments: [], builtIn: false, notes: ""
    )

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

    func testDuplicateToolIDsKeepStableRawItemIdentity() {
        let profile = AgentProfile(
            id: "perf", title: "Perf", subtitle: "", command: "true",
            arguments: [], builtIn: false, notes: ""
        )
        let first = PerfFixture.toolCall(turn: 0, index: 0)
        var second = first
        second.title = "second"
        let firstID = UUID()
        let secondID = UUID()
        let session = ChatSession(agent: profile, cwd: "/tmp", phase: .ready)
        session.replaceTranscript([.tool(firstID, first), .tool(secondID, second)], runs: [:])

        var update = second
        update.status = "completed"
        session.apply(SessionNotification(sessionId: "s", update: .toolCallUpdate(update)))

        guard case .tool(let id, let call) = session.items.last else {
            return XCTFail("expected tool")
        }
        XCTAssertEqual(id, secondID)
        XCTAssertEqual(call.status, "completed")
        XCTAssertEqual(session.items.map(\.id), [firstID, secondID])
    }

    func testDuplicateAgentChunkDoesNotRevise() {
        let session = ChatSession(agent: Self.perfProfile, cwd: "/tmp", phase: .ready)
        session.apply(SessionNotification(
            sessionId: "perf",
            update: .agentMessageChunk(.text("Hello"))
        ))
        let revision = session.transcriptRevision
        session.apply(SessionNotification(
            sessionId: "perf",
            update: .agentMessageChunk(.text("Hello"))
        ))
        XCTAssertEqual(session.transcriptRevision, revision)
    }

    func testSidebarListingOrdersShortcutsAndOrphans() {
        let agent = Aureways.AgentProfile(
            id: "perf", title: "Perf", subtitle: "", command: "true",
            arguments: [], builtIn: false, notes: ""
        )
        let added = Date(timeIntervalSince1970: 1)
        let wsA = Aureways.WorkspaceRecord(path: "/tmp/alpha", addedAt: added, lastUsedAt: added)
        let wsB = Aureways.WorkspaceRecord(path: "/tmp/beta", addedAt: added, lastUsedAt: added)
        let s1 = Aureways.ChatSession(agent: agent, cwd: "/tmp/alpha", title: "One", phase: .ready)
        let s2 = Aureways.ChatSession(agent: agent, cwd: "/tmp/beta", title: "Two", phase: .ready)
        let orphan = Aureways.ChatSession(agent: agent, cwd: "/tmp/orphan", title: "Orphan", phase: .ready)
        let closed = Aureways.ChatSession(agent: agent, cwd: "/tmp/alpha", title: "Gone", phase: .ready)
        closed.isClosed = true

        let snap = SidebarListing.make(
            sessions: [s1, s2, orphan, closed],
            workspaces: [wsA, wsB],
            searchQuery: ""
        )
        XCTAssertEqual(snap.filtered.map(\.id), [s1.id, s2.id, orphan.id])
        XCTAssertEqual(snap.ordered.map(\.id), [s1.id, s2.id, orphan.id])
        XCTAssertEqual(snap.shortcutByID[s1.id], "⌘1")
        XCTAssertEqual(snap.shortcutByID[s2.id], "⌘2")
        XCTAssertEqual(snap.shortcutByID[orphan.id], "⌘3")
        XCTAssertNil(snap.shortcutByID[closed.id])

        let search = SidebarListing.make(
            sessions: [s1, s2, orphan, closed],
            workspaces: [wsA, wsB],
            searchQuery: "Orph"
        )
        XCTAssertEqual(search.ordered.map(\.id), [orphan.id])
        XCTAssertEqual(search.shortcutByID[orphan.id], "⌘1")
        XCTAssertTrue(search.visibleWorkspaces.isEmpty)
    }

    func testInboxPushArmsOnlyFromEmpty() {
        let inbox = SessionUpdateInbox()
        let event = SessionUpdateInbox.Event(
            agentId: "a",
            notification: Aureways.SessionNotification(
                sessionId: "s",
                update: .agentMessageChunk(.text("x"))
            )
        )
        XCTAssertTrue(inbox.push(event))
        XCTAssertFalse(inbox.push(event))
        XCTAssertEqual(inbox.take().count, 2)
        XCTAssertTrue(inbox.push(event))
    }

    func testOverflowThresholdAndWorkspaceDraft() throws {
        XCTAssertFalse(ComposerOverflow.exceedsInlineLimit(String(repeating: "a", count: ComposerOverflow.inlineUTF16Limit)))
        XCTAssertTrue(ComposerOverflow.exceedsInlineLimit(String(repeating: "a", count: ComposerOverflow.inlineUTF16Limit + 1)))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aureways-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = String(repeating: "字", count: ComposerOverflow.inlineUTF16Limit + 10)
        let url = try ComposerOverflow.write(text, inWorkspace: root.path)
        XCTAssertTrue(ComposerOverflow.isPastePath(url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)

        let attachment = ComposerOverflow.pastedAttachment(url: url, characterCount: ComposerOverflow.utf16Count(text))
        XCTAssertEqual(attachment.kind, .pastedText)
        XCTAssertEqual(attachment.transcriptAttachment.kind, "pastedText")
        XCTAssertTrue(attachment.transcriptAttachment.isPastedText)
        XCTAssertEqual(attachment.transcriptAttachment.path, url.path)
        XCTAssertEqual(attachment.transcriptAttachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.transcriptAttachment.characterCount, ComposerOverflow.utf16Count(text))

        let tooLarge = String(repeating: "a", count: ComposerOverflow.maxBytes + 1)
        XCTAssertThrowsError(try ComposerOverflow.write(tooLarge, inWorkspace: root.path)) { error in
            XCTAssertEqual(error as? ComposerOverflow.WriteError, .tooLarge)
        }
    }

    func testClassifyTextTooLarge() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.aureways.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "a", count: ComposerOverflow.maxBytes + 1), forType: .string)
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(ComposerOverflow.classifyText(on: pasteboard), .tooLarge)
    }

    /// Web composer paste (⌘V with files on the pasteboard) goes through
    /// `ComposerAttachment.fromPasteboard`.
    func testPasteImageFileURLBecomesAttachment() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: NSSize(width: 8, height: 8)).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.aureways.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        defer { pasteboard.releaseGlobally() }

        let attachments = ComposerAttachment.fromPasteboard(pasteboard)
        XCTAssertEqual(attachments.count, 1, "粘贴图片文件 URL 应产出图片附件")
        XCTAssertEqual(attachments.first?.kind, .image)
        XCTAssertEqual(attachments.first?.name, url.lastPathComponent)
    }
}
