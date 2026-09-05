#if DEBUG
import Foundation
import Synchronization

/// Debug-build counters for the transcript work that is suspected of running
/// per scroll frame. `TranscriptBlock.group` is nonisolated, so the counter is
/// an atomic rather than main-actor state.
enum PerfCounters {
    private static let groupCallCount = Atomic<Int>(0)

    /// Bumped by `TranscriptBlock.group(_:runs:)`, which `TranscriptView.body`
    /// calls once per evaluation — so this doubles as a body-evaluation count.
    static var groupCalls: Int { groupCallCount.load(ordering: .relaxed) }

    static func countGroupCall() {
        groupCallCount.add(1, ordering: .relaxed)
    }

    static func reset() {
        groupCallCount.store(0, ordering: .relaxed)
    }
}

/// Deterministic transcript fixture for scroll-performance work.
///
/// Shared by `TranscriptPerfTests` (micro-benchmarks) and, when
/// `AUREWAYS_PERF_TURNS` is set, by the app itself so a trace can be recorded
/// against a known transcript instead of a live agent conversation:
///
///     AUREWAYS_PERF_TURNS=50 open -a Aureways        # 350 items / 300 blocks
///
/// Debug builds only; never compiled into Release.
enum PerfFixture {

    /// Items per turn: user, thought, 3 tool calls, plan, agent reply.
    static let itemsPerTurn = 7

    /// A transcript shaped like a real coding session.
    static func items(turns: Int) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for turn in 0..<turns {
            items.append(.user(UUID(), "把 \(turn) 号文件里的重复逻辑收敛一下", []))
            items.append(.thought(UUID(), String(repeating: "先读一遍现有实现，确认调用点。", count: 4)))
            for call in 0..<3 {
                items.append(.tool(UUID(), toolCall(turn: turn, index: call)))
            }
            items.append(.plan(UUID(), plan()))
            items.append(.agent(UUID(), agentReply(turn)))
        }
        return items
    }

    /// Activity runs for the fixture, so summary rows render a duration.
    static func runs(for items: [TranscriptItem]) -> [UUID: ActivityRun] {
        var runs: [UUID: ActivityRun] = [:]
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        for item in items {
            if case .thought(let id, _) = item {
                runs[id] = ActivityRun(startedAt: start, endedAt: start.addingTimeInterval(2))
            }
        }
        return runs
    }

    static func toolCall(turn: Int, index: Int) -> ToolCallView {
        let path = "/Volumes/app/DevelopProject/Aureways/Aureways/Views/Transcript\(turn).swift"
        return ToolCallView(json: .object([
            "toolCallId": .string("call_\(turn)_\(index)"),
            "title": .string("Read `\(path)`"),
            "kind": .string(index == 1 ? "edit" : "read"),
            "status": .string("completed"),
            "rawInput": .object([
                "file_path": .string(path),
                "offset": .number(Double(index * 40)),
                "limit": .number(120)
            ]),
            "content": .array([
                .object([
                    "type": .string("content"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(String(repeating: "line of tool output\n", count: 30))
                    ])
                ])
            ]),
            "locations": .array([
                .object(["path": .string(path), "line": .number(Double(index * 12 + 3))])
            ])
        ]))
    }

    static func plan() -> [PlanEntry] {
        [
            ("读取现有实现", "completed"),
            ("抽出公共方法", "in_progress"),
            ("补测试", "pending")
        ].compactMap { content, status in
            PlanEntry(json: .object(["content": .string(content), "status": .string(status)]))
        }
    }

    /// Set to drop the fenced code block from the fixture, so the cost of
    /// highlight.js can be separated from everything else.
    static var omitsCode: Bool {
        ProcessInfo.processInfo.environment["AUREWAYS_PERF_NOCODE"] == "1"
    }

    /// An agent reply with prose, a list and a fenced code block — the shape
    /// that drives both the markdown pre-render and highlight.js.
    static func agentReply(_ n: Int) -> String {
        let code = omitsCode ? "" : """

        ```swift
        stack(lazy: session.isStreaming) {
            ForEach(blocks) { block in
                TranscriptBlockView(block: block, isStreaming: block.id == liveID)
                    .equatable()
                    .id(block.id)
            }
        }
        ```
        """
        return """
        我看了第 \(n) 处实现。问题在于滚动几何变化每帧都会写一次 `@State`。

        - 非流式时走的是普通 `VStack`，没有虚拟化
        - `TranscriptBlock.group(_:runs:)` 在 `body` 里，每次求值都重新分配
        - `onScrollGeometryChange` 的 transform 返回值每帧都在变
        \(code)

        建议把分组结果缓存到 `ChatSession` 上，`body` 只读数组。
        """
    }

    /// Turn count requested via the environment, or `nil` when unset.
    static var requestedTurns: Int? {
        guard let raw = ProcessInfo.processInfo.environment["AUREWAYS_PERF_TURNS"],
              let turns = Int(raw), turns > 0 else { return nil }
        return turns
    }
}

#endif
