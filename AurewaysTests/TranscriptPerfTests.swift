import XCTest
import SwiftStreamingMarkdown
@testable import SwiftStreamingMarkdown
@testable import Aureways

/// Step-0 baseline for the transcript scrolling work. These are measurements,
/// not assertions about behaviour: each one prints a number so the effect of a
/// later change is visible in the same log line.
///
/// Run with:
///   make test 2>&1 | grep 'PERF '
final class TranscriptPerfTests: XCTestCase {

    // MARK: - Measurements

    /// `TranscriptView.body` calls `group()` on every evaluation, and
    /// `onScrollGeometryChange` invalidates it on every scroll frame.
    func testGroupCostPerBodyEvaluation() {
        for turns in [10, 50, 100] {
            let items = PerfFixture.items(turns: turns)
            let runs = PerfFixture.runs(for: items)
            let blocks = TranscriptBlock.group(items, runs: runs)
            let ms = time(iterations: 200) {
                _ = TranscriptBlock.group(items, runs: runs)
            }
            report(
                "group() items=\(items.count) blocks=\(blocks.count)",
                ms,
                extra: String(format: "= %.1f%% of an 8.3ms frame", ms / 8.3 * 100)
            )
        }
    }

    /// What `.equatable()` on `TranscriptBlockView` pays per comparison, times
    /// the number of rows in the transcript.
    func testBlockEqualityCost() {
        let items = PerfFixture.items(turns: 50)
        let runs = PerfFixture.runs(for: items)
        let lhs = TranscriptBlock.group(items, runs: runs)
        let rhs = TranscriptBlock.group(items, runs: runs)
        let ms = time(iterations: 200) {
            for (a, b) in zip(lhs, rhs) where a == b { }
        }
        report("== over \(lhs.count) blocks", ms)
    }

    /// If `group()` mints a fresh UUID on any path, block identity changes on
    /// every body evaluation and `ForEach` tears the whole row down.
    func testBlockIdentityIsStableAcrossCalls() {
        let items = PerfFixture.items(turns: 20)
        let runs = PerfFixture.runs(for: items)
        let first = TranscriptBlock.group(items, runs: runs).map(\.id)
        let second = TranscriptBlock.group(items, runs: runs).map(\.id)
        XCTAssertEqual(first, second, "block identity churns between body evaluations")
    }

    @MainActor
    func testToolProjectionMatchesFullGroupingAndNoOpDoesNotRevise() {
        let profile = AgentProfile(
            id: "perf", title: "Perf", subtitle: "", command: "true",
            arguments: [], builtIn: false, notes: ""
        )
        let session = ChatSession(agent: profile, cwd: "/tmp", phase: .ready)
        let items = PerfFixture.items(turns: 20)
        session.replaceTranscript(items, runs: PerfFixture.runs(for: items))

        for step in 0..<100 {
            session.apply(PerfFixture.toolUpdate(turn: 19, index: 2, step: step))
            let expected = TranscriptBlock.group(session.items, runs: session.activityRuns)
            XCTAssertEqual(session.transcriptEntries.map(\.block), expected)
        }

        let revision = session.transcriptRevision
        session.apply(PerfFixture.toolUpdate(turn: 19, index: 2, step: 99))
        XCTAssertEqual(session.transcriptRevision, revision)
    }

    @MainActor
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
        guard case .activity(_, let steps, _) = session.transcriptEntries.last?.block,
              case .tools(_, let tools) = steps.last else {
            return XCTFail("expected projected tools")
        }
        XCTAssertEqual(tools.map(\.id), [firstID, secondID])
    }

    func testVirtualizerWindowCoversViewport() {
        let heights: [CGFloat] = Array(repeating: 100, count: 20)
        let window = TranscriptVirtualizer.window(
            rowHeights: heights,
            offset: 0,
            viewport: 250,
            overscan: 0,
            spacing: 16
        )
        XCTAssertEqual(window.start, 0)
        XCTAssertGreaterThan(window.end, window.start)
        XCTAssertEqual(window.topHeight, 0)
        XCTAssertGreaterThan(window.bottomHeight, 0)
        XCTAssertLessThan(window.end, heights.count)
    }

    func testVirtualizerWindowAtBottomIncludesLastRow() {
        let heights: [CGFloat] = Array(repeating: 100, count: 20)
        let window = TranscriptVirtualizer.window(
            rowHeights: heights,
            offset: .infinity,
            viewport: 250,
            overscan: 0,
            spacing: 16
        )
        XCTAssertEqual(window.end, heights.count)
        XCTAssertGreaterThan(window.start, 0)
        XCTAssertEqual(window.bottomHeight, 0)
        XCTAssertGreaterThan(window.topHeight, 0)
    }

    func testExpandingVisibleRowDoesNotCollapseTopSpacer() {
        let heights: [CGFloat] = Array(repeating: 100, count: 8)
        let before = TranscriptVirtualizer.window(
            rowHeights: heights,
            offset: 150,
            viewport: 120,
            overscan: 0,
            spacing: 16
        )
        XCTAssertGreaterThan(before.start, 0)
        var expanded = heights
        expanded[before.start] += 400
        let after = TranscriptVirtualizer.window(
            rowHeights: expanded,
            offset: 150,
            viewport: 120,
            overscan: 0,
            spacing: 16
        )
        XCTAssertEqual(after.start, before.start)
        XCTAssertEqual(after.topHeight, before.topHeight)
    }

    func testEmptyTranscriptWindow() {
        let window = TranscriptVirtualizer.window(rowHeights: [], offset: 0, viewport: 400)
        XCTAssertEqual(window, .empty)
    }

    @MainActor
    func testHeightCachePruneRemovesStaleKeysWhenCountsMatch() {
        let cache = TranscriptHeightCache()
        let stale = UUID()
        let live = UUID()
        _ = cache.set(stale, 40)
        XCTAssertEqual(cache.prune(keeping: [live]), 1)
        XCTAssertEqual(cache.prune(keeping: [live]), 0)
    }

    @MainActor
    func testHeightCacheAppendFastPathMatchesFullPrefixSums() {
        let cache = TranscriptHeightCache()
        let first = TranscriptEntry(block: .agent(UUID(), "one"))
        let second = TranscriptEntry(block: .agent(UUID(), "two"))
        _ = cache.set(first.id, 100)
        _ = cache.set(second.id, 50)
        _ = cache.window(for: [first], offset: 0, viewport: 720, overscan: 0)
        let fast = cache.window(for: [first, second], offset: 0, viewport: 40, overscan: 0)
        let expected = TranscriptVirtualizer.window(
            rowHeights: [100, 50],
            offset: 0,
            viewport: 40,
            overscan: 0,
            spacing: TranscriptVirtualizer.spacing
        )
        XCTAssertEqual(fast, expected)
    }

    @MainActor
    func testHeightCacheLastRowVersionBumpUsesFastPath() {
        let cache = TranscriptHeightCache()
        var entries: [TranscriptEntry] = []
        for index in 0..<10 {
            let entry = TranscriptEntry(block: .agent(UUID(), "row \(index)"))
            _ = cache.set(entry.id, 40)
            entries.append(entry)
        }
        _ = cache.window(for: entries, offset: 0, viewport: 100, overscan: 0)
        PerfCounters.reset()

        let last = entries[9]
        for step in 1...100 {
            last.version = UInt64(step)
            last.block = .agent(last.id, String(repeating: "x", count: step * 8))
            _ = cache.window(for: entries, offset: 0, viewport: 100, overscan: 0)
        }

        XCTAssertEqual(PerfCounters.indexLastRowUpdates, 100)
        XCTAssertEqual(PerfCounters.indexFullRebuilds, 0)
        let window = cache.window(for: entries, offset: 0, viewport: 100, overscan: 0)
        let expected = TranscriptVirtualizer.window(
            rowHeights: Array(repeating: 40, count: 10),
            offset: 0,
            viewport: 100,
            overscan: 0,
            spacing: TranscriptVirtualizer.spacing
        )
        XCTAssertEqual(window, expected)
    }

    @MainActor
    func testLiveTextProjectionScaleCurve() {
        print("\n=== PERF_CURVE LIVE_TEXT_PROJECTION ===")
        print("turns,rebuilds,updates,apply_ms")
        let chunk = "The quick brown fox jumps over the lazy dog. "
        for turns in [10, 50, 100] {
            let session = ChatSession(agent: Self.perfProfile, cwd: "/tmp", phase: .ready)
            let items = PerfFixture.items(turns: turns)
            session.replaceTranscript(items, runs: PerfFixture.runs(for: items))
            PerfCounters.reset()
            let iterations = 200
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                session.apply(SessionNotification(
                    sessionId: "perf",
                    update: .agentMessageChunk(.text(chunk))
                ))
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let applyMs = Double(t1 - t0) / Double(iterations) / 1_000_000
            print(String(
                format: "PERF_CURVE turns=%3d rebuilds=%3d updates=%3d apply=%7.4fms",
                turns,
                PerfCounters.projectionRebuilds,
                PerfCounters.projectionUpdates,
                applyMs
            ))
            print(String(
                format: "DATA:%d,%d,%d,%.4f",
                turns,
                PerfCounters.projectionRebuilds,
                PerfCounters.projectionUpdates,
                applyMs
            ))
            XCTAssertEqual(PerfCounters.projectionRebuilds, 0)
            XCTAssertEqual(PerfCounters.projectionUpdates, iterations)
        }
    }

    @MainActor
    func testLiveTextProjectionMatchesFullGroupingAndPreservesEarlierEntries() {
        let session = ChatSession(agent: Self.perfProfile, cwd: "/tmp", phase: .ready)
        let items = PerfFixture.items(turns: 20)
        session.replaceTranscript(items, runs: PerfFixture.runs(for: items))
        let priorIDs = session.transcriptEntries.dropLast().map(\.id)
        let priorVersions = session.transcriptEntries.dropLast().map(\.version)
        let priorObjects = session.transcriptEntries.dropLast().map { ObjectIdentifier($0) }

        for step in 0..<40 {
            session.apply(SessionNotification(
                sessionId: "perf",
                update: .agentMessageChunk(.text(" token-\(step)"))
            ))
            let expected = TranscriptBlock.group(session.items, runs: session.activityRuns)
            XCTAssertEqual(session.transcriptEntries.map(\.block), expected)
        }

        XCTAssertEqual(session.transcriptEntries.dropLast().map(\.id), Array(priorIDs))
        XCTAssertEqual(session.transcriptEntries.dropLast().map(\.version), Array(priorVersions))
        XCTAssertEqual(session.transcriptEntries.dropLast().map { ObjectIdentifier($0) }, Array(priorObjects))
    }

    @MainActor
    func testNewAgentMessageRebuildsThenContinuesLocally() {
        let session = ChatSession(agent: Self.perfProfile, cwd: "/tmp", phase: .ready)
        session.appendUser("hello")
        PerfCounters.reset()
        session.apply(SessionNotification(
            sessionId: "perf",
            update: .agentMessageChunk(.text("First token"))
        ))
        XCTAssertEqual(PerfCounters.projectionRebuilds, 1)
        XCTAssertEqual(PerfCounters.projectionUpdates, 0)
        session.apply(SessionNotification(
            sessionId: "perf",
            update: .agentMessageChunk(.text(" more"))
        ))
        XCTAssertEqual(PerfCounters.projectionRebuilds, 1)
        XCTAssertEqual(PerfCounters.projectionUpdates, 1)
        guard case .agent(_, let text) = session.transcriptEntries.last?.block else {
            return XCTFail("expected agent block")
        }
        XCTAssertEqual(text, "First token more")
    }

    @MainActor
    func testThoughtLiveProjectionUpdatesActivityStep() {
        let session = ChatSession(agent: Self.perfProfile, cwd: "/tmp", phase: .ready)
        session.appendUser("hello")
        session.apply(SessionNotification(
            sessionId: "perf",
            update: .agentThoughtChunk(.text("Considering"))
        ))
        PerfCounters.reset()
        session.apply(SessionNotification(
            sessionId: "perf",
            update: .agentThoughtChunk(.text(" the layout"))
        ))
        XCTAssertEqual(PerfCounters.projectionRebuilds, 0)
        XCTAssertEqual(PerfCounters.projectionUpdates, 1)
        let expected = TranscriptBlock.group(session.items, runs: session.activityRuns)
        XCTAssertEqual(session.transcriptEntries.map(\.block), expected)
        guard case .activity(_, let steps, _) = session.transcriptEntries.last?.block,
              case .thought(_, let text) = steps.last else {
            return XCTFail("expected thought step")
        }
        XCTAssertEqual(text, "Considering the layout")
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    // MARK: - Helpers

    private static let perfProfile = AgentProfile(
        id: "perf", title: "Perf", subtitle: "", command: "true",
        arguments: [], builtIn: false, notes: ""
    )

    private func time(iterations: Int, _ body: () -> Void) -> Double {
        body()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / Double(iterations) / 1_000_000
    }

    private func report(_ label: String, _ ms: Double, extra: String = "") {
        print(String(format: "PERF  %-44@ %8.4f ms  %@", label as NSString, ms, extra as NSString))
    }

    // MARK: - PERF-00 Size Curve & Streaming Benchmarks

    /// Document size vs parse / renderable construction latency curve:
    /// Tests 0.5 KB, 2 KB, 10 KB, 50 KB, 100 KB, 250 KB
    func testMarkdownDocumentSizeCurve() async {
        let sizesInKB = [0.5, 2.0, 10.0, 50.0, 100.0, 250.0]
        let parser = MarkdownParserImpl()
        let config = AurewaysMarkdown.plain

        print("\n=== PERF_CURVE MARKDOWN_SIZE_VS_PARSE ===")
        print("size_kb,chars,parse_ms,render_build_ms,total_ms")

        for sizeKB in sizesInKB {
            let targetBytes = Int(sizeKB * 1024)
            let markdown = generateMarkdownSample(targetBytes: targetBytes)

            // Warm up
            _ = await parser.parse(text: markdown, option: .init(speculativeRewrite: false))

            var totalParseNs: UInt64 = 0
            var totalRenderNs: UInt64 = 0
            let iterations = max(3, min(20, Int(200.0 / sizeKB)))

            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let parseResult = await parser.parse(text: markdown, option: .init(speculativeRewrite: false))
                let t1 = DispatchTime.now().uptimeNanoseconds
                _ = await RenderableDocument(document: parseResult.document, config: config)
                let t2 = DispatchTime.now().uptimeNanoseconds

                totalParseNs += (t1 - t0)
                totalRenderNs += (t2 - t1)
            }

            let parseMs = Double(totalParseNs) / Double(iterations) / 1_000_000
            let renderMs = Double(totalRenderNs) / Double(iterations) / 1_000_000
            let totalMs = parseMs + renderMs

            print(String(format: "PERF_CURVE size=%6.1fKB chars=%6d parse=%8.3fms render=%8.3fms total=%8.3fms",
                         sizeKB, markdown.count, parseMs, renderMs, totalMs))
            print(String(format: "DATA:%.1f,%d,%.3f,%.3f,%.3f",
                         sizeKB, markdown.count, parseMs, renderMs, totalMs))
        }
    }

    /// Streaming append tick rates & processing cost:
    /// Tests 10 Hz, 30 Hz, 60 Hz, 120 Hz tick simulation over growing markdown snapshots
    func testStreamingTickRatePerformance() async {
        print("\n=== PERF_CURVE STREAMING_TICK_RATE ===")
        print("tick_hz,token_chunk_len,total_ticks,avg_tick_cost_ms,est_frame_budget_pct")

        let testFrequencies = [10, 30, 60, 120]
        let baseChunk = "The quick brown fox jumps over the lazy dog. Here is some math $E=mc^2$ and `code()`. "
        let parser = MarkdownParserImpl()
        let config = AurewaysMarkdown.animated

        for hz in testFrequencies {
            var doc = "# Streaming Benchmark Test\n\n"
            let totalTicks = 30
            var totalTickNs: UInt64 = 0

            for _ in 0..<totalTicks {
                doc += baseChunk
                let t0 = DispatchTime.now().uptimeNanoseconds
                let result = await parser.parse(text: doc, option: .init(speculativeRewrite: false))
                _ = await RenderableDocument(document: result.document, config: config)
                let t1 = DispatchTime.now().uptimeNanoseconds
                totalTickNs += (t1 - t0)
            }

            let avgTickMs = Double(totalTickNs) / Double(totalTicks) / 1_000_000
            let frameBudgetMs = 1000.0 / Double(hz)
            let budgetPct = (avgTickMs / frameBudgetMs) * 100.0

            print(String(format: "PERF_CURVE hz=%3d ticks=%2d avg_tick=%7.3fms budget_consumed=%6.1f%%",
                         hz, totalTicks, avgTickMs, budgetPct))
            print(String(format: "DATA:%d,%d,%d,%.3f,%.1f%%",
                         hz, baseChunk.count, totalTicks, avgTickMs, budgetPct))
        }
    }

    private func generateMarkdownSample(targetBytes: Int) -> String {
        var sample = "# Sample Document\n\n"
        let paragraph = "This is a benchmark sample paragraph containing **bold text**, *italics*, inline math $\\alpha + \\beta = \\gamma$, and `code identifiers`. It simulates realistic LLM streaming text outputs.\n\n"
        let codeBlock = "```swift\nfunc processData(values: [Int]) -> Int {\n    return values.reduce(0, +)\n}\n```\n\n"
        let table = "| Col A | Col B | Col C |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| $x$ | $y$ | $z$ |\n\n"

        while sample.utf8.count < targetBytes {
            sample += paragraph
            if sample.utf8.count < targetBytes {
                sample += codeBlock
            }
            if sample.utf8.count < targetBytes {
                sample += table
            }
        }
        return sample
    }

    /// Benchmark scaling curve for rowHeights calculation, window virtualizer queries, and prune
    /// over 10, 50, and 100 conversational turns (PERF-04).
    @MainActor
    func testTranscriptVirtualizerScaleCurve() async {
        print("\n=== PERF_CURVE TRANSCRIPT_VIRTUALIZER_SCALE ===")
        print("turns,entries,row_heights_ms,scroll_60fps_ms,prune_ms")

        let turnCounts = [10, 50, 100]
        let cache = TranscriptHeightCache()

        for turns in turnCounts {
            var entries: [TranscriptEntry] = []
            var liveIDs: Set<UUID> = []
            for t in 0..<turns {
                let uID = UUID()
                let uEntry = TranscriptEntry(block: .user(uID, "User prompt turn " + String(t), []))
                let aID = UUID()
                let aEntry = TranscriptEntry(block: .agent(aID, "Agent response turn " + String(t) + " with detailed analysis and code."))
                let sID = UUID()
                let sEntry = TranscriptEntry(block: .status(sID, "Status update for turn " + String(t)))
                entries.append(contentsOf: [uEntry, aEntry, sEntry])
                liveIDs.insert(uID)
                liveIDs.insert(aID)
                liveIDs.insert(sID)
                _ = cache.set(uID, 64)
                _ = cache.set(aID, 120)
                _ = cache.set(sID, 40)
            }

            // 1. rowHeights measurement
            let iter = 50
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iter {
                _ = cache.rowHeights(for: entries)
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let rowHeightsMs = Double(t1 - t0) / Double(iter) / 1_000_000

            // 2. 60 frames scroll window queries
            let scrollFrames = 60
            let t2 = DispatchTime.now().uptimeNanoseconds
            for frame in 0..<scrollFrames {
                let offset = CGFloat(frame * 20)
                _ = cache.window(for: entries, offset: offset, viewport: 720)
            }
            let t3 = DispatchTime.now().uptimeNanoseconds
            let scroll60fpsMs = Double(t3 - t2) / Double(scrollFrames) / 1_000_000

            // 3. Prune measurement
            let t4 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iter {
                cache.prune(keeping: liveIDs)
            }
            let t5 = DispatchTime.now().uptimeNanoseconds
            let pruneMs = Double(t5 - t4) / Double(iter) / 1_000_000

            print(String(format: "PERF_CURVE turns=%3d entries=%3d rowHeights=%7.4fms scrollFrame=%7.4fms prune=%7.4fms",
                         turns, entries.count, rowHeightsMs, scroll60fpsMs, pruneMs))
            print(String(format: "DATA:%d,%d,%.4f,%.4f,%.4f",
                         turns, entries.count, rowHeightsMs, scroll60fpsMs, pruneMs))
        }
    }


    func testAdjacentAgentItemsMergeIntoOneAgentBlock() {
        let u1 = UUID()
        let a1 = UUID()
        let a2 = UUID()
        let t1 = UUID()
        let a3 = UUID()

        let items: [TranscriptItem] = [
            .user(u1, "Hello", []),
            .agent(a1, "First paragraph."),
            .agent(a2, "Second paragraph."),
            .thought(t1, "Thinking..."),
            .agent(a3, "After thought.")
        ]

        let blocks = TranscriptBlock.group(items)
        // Expected: user, agent (merged a1+a2), activity (thought t1), agent (a3)
        XCTAssertEqual(blocks.count, 4)
        if case .agent(let id, let text) = blocks[1] {
            XCTAssertEqual(id, a1)
            XCTAssertEqual(text, "First paragraph.\n\nSecond paragraph.")
        } else {
            XCTFail("Expected blocks[1] to be .agent")
        }

        if case .agent(let id, let text) = blocks[3] {
            XCTAssertEqual(id, a3)
            XCTAssertEqual(text, "After thought.")
        } else {
            XCTFail("Expected blocks[3] to be .agent")
        }
    }

}
