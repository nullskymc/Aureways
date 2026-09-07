import Foundation

// MARK: - Grouped blocks

/// One entry inside an activity card: a thought, a run of tool calls, or a plan.
enum ActivityStep: Identifiable, Equatable {
    case thought(UUID, String)
    case tools(UUID, [ToolCallView])
    case plan(UUID, [PlanEntry])

    var id: UUID {
        switch self {
        case .thought(let id, _), .tools(let id, _), .plan(let id, _):
            return id
        }
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
    static func group(_ items: [TranscriptItem], runs: [UUID: ActivityRun] = [:]) -> [TranscriptBlock] {
        #if DEBUG
        PerfCounters.countGroupCall()
        #endif
        var blocks: [TranscriptBlock] = []
        var steps: [ActivityStep] = []
        var activityID: UUID?
        var tools: [ToolCallView] = []
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
            for (id, text) in pendingAgents {
                blocks.append(.agent(id, text))
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
                tools.append(call)
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
