import SwiftUI

// MARK: - Grouped blocks

enum ActivityStep: Identifiable {
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

enum TranscriptBlock: Identifiable {
    case user(UUID, String)
    case agent(UUID, String)
    case activity(UUID, [ActivityStep])
    case status(UUID, String)

    var id: UUID {
        switch self {
        case .user(let id, _), .agent(let id, _), .activity(let id, _), .status(let id, _):
            return id
        }
    }

    /// Collapse thought + tool + plan runs into one card per assistant turn.
    static func group(_ items: [TranscriptItem]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var steps: [ActivityStep] = []
        var activityID: UUID?
        var tools: [ToolCallView] = []
        var toolsID: UUID?

        func flushTools() {
            guard !tools.isEmpty else { return }
            steps.append(.tools(toolsID ?? UUID(), tools))
            tools = []
            toolsID = nil
        }

        func flushActivity() {
            flushTools()
            guard !steps.isEmpty else { return }
            blocks.append(.activity(activityID ?? steps[0].id, steps))
            steps = []
            activityID = nil
        }

        for item in items {
            switch item {
            case .user(let id, let text):
                flushActivity()
                blocks.append(.user(id, text))
            case .agent(let id, let text):
                flushActivity()
                blocks.append(.agent(id, text))
            case .thought(let id, let text):
                flushTools()
                if activityID == nil { activityID = id }
                steps.append(.thought(id, text))
            case .tool(let id, let call):
                if activityID == nil { activityID = id }
                if tools.isEmpty { toolsID = id }
                tools.append(call)
            case .plan(let id, let entries):
                flushTools()
                if activityID == nil { activityID = id }
                steps.append(.plan(id, entries))
            case .status(_, let text) where isNoiseStatus(text):
                continue
            case .status(let id, let text):
                flushActivity()
                blocks.append(.status(id, text))
            }
        }
        flushActivity()
        return blocks
    }

    private static func isNoiseStatus(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("stop:") || lowered.hasPrefix("mode:")
    }
}

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    var isStreaming = false

    var body: some View {
        switch block {
        case .user(_, let text):
            UserBubble(text: text)
        case .agent(_, let text):
            AgentMessage(markdown: text)
        case .activity(_, let steps):
            ActivityCard(steps: steps, isLive: isStreaming)
        case .status(_, let text):
            ErrorNotice(text: text)
        }
    }
}

private struct ErrorNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 8)
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Palette.cardHover,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }
}

private struct AgentMessage: View {
    let markdown: String

    var body: some View {
        MarkdownBody(source: markdown)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityCard: View {
    let steps: [ActivityStep]
    var isLive: Bool
    @State private var userExpanded: Bool?
    @State private var openCallID: String?

    private var isExpanded: Bool {
        userExpanded ?? isLive
    }

    private var toolCalls: [ToolCallView] {
        steps.flatMap { step -> [ToolCallView] in
            if case .tools(_, let calls) = step { return calls }
            return []
        }
    }

    private var isBusy: Bool {
        isLive || toolCalls.contains { call in
            let value = call.status.lowercased()
            return value != "completed" && value != "success" && value != "failed" && value != "error"
        }
    }

    private var failedCount: Int {
        toolCalls.filter { ["failed", "error"].contains($0.status.lowercased()) }.count
    }

    private var thoughtCount: Int {
        steps.reduce(0) { count, step in
            if case .thought = step { return count + 1 }
            return count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    userExpanded = !isExpanded
                }
            } label: {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: failedCount > 0 ? "xmark.circle" : "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(failedCount > 0 ? Color.red : Palette.moss)
                    }
                    Text(summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { step in
                        stepView(step)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 8)
    }

    private var summary: String {
        let tools = toolCalls.count
        if isBusy {
            if tools > 0 { return "正在思考并使用工具" }
            return "正在思考"
        }
        var parts: [String] = []
        if thoughtCount > 0 { parts.append("思考") }
        if tools == 1 { parts.append("1 个工具") }
        else if tools > 1 { parts.append("\(tools) 个工具") }
        if failedCount > 0 { parts.append("\(failedCount) 失败") }
        if parts.isEmpty { return "工作记录" }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func stepView(_ step: ActivityStep) -> some View {
        switch step {
        case .thought(_, let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tools(_, let calls):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(calls, id: \.toolCallId) { call in
                    ToolCompactRow(call: call, isOpen: openCallID == call.toolCallId) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            openCallID = openCallID == call.toolCallId ? nil : call.toolCallId
                        }
                    }
                }
            }
        case .plan(_, let entries):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: entry.status == "completed" ? "checkmark.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(entry.status == "completed" ? Palette.moss : Color.secondary.opacity(0.55))
                        Text(entry.content)
                            .font(.system(size: 12))
                            .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                    }
                }
            }
        }
    }
}

