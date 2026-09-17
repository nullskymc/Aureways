import Foundation
import Observation

// MARK: - Grouped blocks

/// One tool inside an activity card. The raw transcript UUID is the UI identity;
/// ACP tool-call IDs may be empty or reused by a provider.
struct ActivityTool: Identifiable, Equatable {
    let id: UUID
    var call: ToolCallView
}

/// One entry inside an activity card: a thought, a run of tool calls, or a plan.
enum ActivityStep: Identifiable, Equatable {
    case thought(UUID, String)
    case tools(UUID, [ActivityTool])
    case plan(UUID, [PlanEntry])

    var id: UUID {
        switch self {
        case .thought(let id, _), .tools(let id, _), .plan(let id, _):
            return id
        }
    }
}

/// Stable reference node consumed by SwiftUI. Updating one tool does not copy or
/// republish the array of all transcript rows.
@Observable
@MainActor
final class TranscriptEntry: Identifiable {
    let id: UUID
    var block: TranscriptBlock
    var version: UInt64

    init(block: TranscriptBlock, version: UInt64 = 0) {
        id = block.id
        self.block = block
        self.version = version
    }
}

/// A renderable row of the transcript, grouped from the raw `TranscriptItem`
/// stream. Pure data — the views live in `Views/TranscriptBlocks.swift`.
enum TranscriptBlock: Identifiable, Equatable {
    case user(UUID, String, [TranscriptAttachment])
    case agent(UUID, String)
    case activity(UUID, [ActivityStep], ActivityRun?)
    case status(UUID, String)

    var id: UUID {
        switch self {
        case .user(let id, _, _), .agent(let id, _), .activity(let id, _, _), .status(let id, _):
            return id
        }
    }

    /// 思考 / 工具 / 计划收成活动卡。正文（含工作流中间那一段）单独成块，
    /// 把活动卡切开，不再塞进卡片里。
    static func group(_ items: [TranscriptItem], runs: [UUID: ActivityRun] = [:], countPerformance: Bool = true) -> [TranscriptBlock] {
        #if DEBUG
        if countPerformance { PerfCounters.countGroupCall() }
        #endif
        var blocks: [TranscriptBlock] = []
        var steps: [ActivityStep] = []
        var activityID: UUID?
        var tools: [ActivityTool] = []
        var toolsID: UUID?
        var pendingAgents: [(UUID, String)] = []

        func flushTools() {
            guard !tools.isEmpty else { return }
            steps.append(.tools(toolsID ?? UUID(), tools))
            tools = []
            toolsID = nil
        }

        func flushActivity() {
            flushTools()
            guard !steps.isEmpty else { return }
            let id = activityID ?? steps[0].id
            blocks.append(.activity(id, steps, combinedRun(for: steps, in: runs)))
            steps = []
            activityID = nil
        }

        func emitPendingAgentsAsBody() {
            guard !pendingAgents.isEmpty else { return }
            flushActivity()
            if pendingAgents.count == 1 {
                blocks.append(.agent(pendingAgents[0].0, pendingAgents[0].1))
            } else {
                let firstID = pendingAgents[0].0
                let combinedText = pendingAgents.map(\.1).joined(separator: "\n\n")
                blocks.append(.agent(firstID, combinedText))
            }
            pendingAgents = []
        }

        for item in items {
            switch item {
            case .user(let id, let text, let attachments):
                emitPendingAgentsAsBody()
                flushActivity()
                blocks.append(.user(id, text, attachments))
            case .agent(let id, let text):
                pendingAgents.append((id, text))
            case .thought(let id, let text):
                emitPendingAgentsAsBody()
                flushTools()
                if activityID == nil { activityID = id }
                steps.append(.thought(id, text))
            case .tool(let id, let call):
                emitPendingAgentsAsBody()
                if activityID == nil { activityID = id }
                if tools.isEmpty { toolsID = id }
                tools.append(ActivityTool(id: id, call: call))
            case .plan(let id, let entries):
                emitPendingAgentsAsBody()
                flushTools()
                if activityID == nil { activityID = id }
                steps.append(.plan(id, entries))
            case .status(_, let text) where isNoiseStatus(text):
                continue
            case .status(let id, let text):
                emitPendingAgentsAsBody()
                flushActivity()
                blocks.append(.status(id, text))
            }
        }
        emitPendingAgentsAsBody()
        flushActivity()
        return blocks
    }

    /// 一张活动卡里的思考 / 工具 / 计划可能来自多个 run，合并成一段时长。
    private static func combinedRun(for steps: [ActivityStep], in runs: [UUID: ActivityRun]) -> ActivityRun? {
        let collected = steps.compactMap { runs[$0.id] }
        guard let first = collected.first else { return nil }
        let startedAt = collected.map(\.startedAt).min() ?? first.startedAt
        guard collected.allSatisfy({ $0.endedAt != nil }) else {
            return ActivityRun(startedAt: startedAt, endedAt: nil)
        }
        return ActivityRun(startedAt: startedAt, endedAt: collected.compactMap(\.endedAt).max())
    }

    private static func isNoiseStatus(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("stop:") || lowered.hasPrefix("mode:")
    }
}
