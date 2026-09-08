import XCTest

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
    /// the number of rows in an eager `VStack`.
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

    // MARK: - Helpers

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
}
