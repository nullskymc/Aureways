import AppKit
import Observation
import SwiftUI

/// Expansion state that outlives row recycling. A windowed transcript destroys
/// off-screen views; `@State` on the card would collapse the measured height
/// the next time the row is placed.
@Observable
@MainActor
final class TranscriptChromeState {
    var activityExpanded: [UUID: Bool] = [:]
    var openToolID: [UUID: UUID] = [:]
    var thoughtExpanded: Set<UUID> = []
}

struct TranscriptBlockView: View, Equatable {
    let block: TranscriptBlock
    var version: UInt64 = 0
    var isStreaming = false
    var chrome: TranscriptChromeState

    // Projection revisions make this O(1), even when a tool carries megabytes.
    // Chrome is a class identity and is not part of equality: expansion updates
    // flow through the observable store, not through this wrapper.
    nonisolated static func == (lhs: TranscriptBlockView, rhs: TranscriptBlockView) -> Bool {
        lhs.block.id == rhs.block.id && lhs.version == rhs.version && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        switch block {
        case .user(_, let text, let attachments):
            UserBubble(text: text, attachments: attachments)
        case .agent(_, let text):
            AgentMessage(markdown: text, isStreaming: isStreaming)
        case .activity(_, let steps, let run):
            ActivityCard(
                blockID: block.id,
                steps: steps,
                isLive: isStreaming,
                run: run,
                chrome: chrome
            )
        case .status(_, let text):
            ErrorNotice(text: text)
        }
    }
}

private struct ErrorNotice: View {
    let text: String

    private var isWaiting: Bool {
        text.hasPrefix(ChatSession.connectRPCPrefix)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isWaiting ? "clock" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(isWaiting ? Palette.gold : Color.red)
            Text(text)
                .font(.system(size: 12, design: text.contains("{") ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct UserBubble: View {
    let text: String
    var attachments: [TranscriptAttachment] = []

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    attachmentRows
                }
                if !text.isEmpty {
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
    }

    private var attachmentRows: some View {
        let images = attachments.filter { $0.kind == "image" }
        let pastes = attachments.filter(\.isPastedText)
        let files = attachments.filter { $0.kind != "image" && !$0.isPastedText }
        return VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(images) { UserAttachmentView(attachment: $0) }
                }
            }
            ForEach(pastes) { UserAttachmentView(attachment: $0) }
            if !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files) { UserAttachmentView(attachment: $0) }
                }
            }
        }
    }
}

private struct UserAttachmentView: View {
    let attachment: TranscriptAttachment
    private let image: NSImage?

    init(attachment: TranscriptAttachment) {
        self.attachment = attachment
        self.image = TranscriptImageStore.cached(attachment) ?? TranscriptImageStore.prefetch(attachment)
    }

    var body: some View {
        if attachment.kind == "image" {
            imageView
        } else if attachment.isPastedText {
            pasteCard
        } else {
            fileChip
        }
    }

    private var pasteCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.sky)
            VStack(alignment: .leading, spacing: 1) {
                Text("粘贴的文本".localized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if attachment.characterCount > 0 {
                    Text("%lld 字".localized(attachment.characterCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.cardHover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private var imageView: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 240, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                )
        } else {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(Palette.cardHover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var fileChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.cardHover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

}

private struct AgentMessage: View {
    let markdown: String
    var isStreaming = false

    @State private var isMessageHovered = false
    @State private var isButtonHovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarkdownBody(source: markdown, isStreaming: isStreaming)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isStreaming && !markdown.isEmpty {
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5))
                            .foregroundStyle(isButtonHovered || copied ? .primary : .secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isButtonHovered ? Color.primary.opacity(0.06) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isButtonHovered = $0 }
                    .help(copied ? "已复制".localized : "复制".localized)

                    Spacer(minLength: 0)
                }
                .opacity(isMessageHovered || copied ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isMessageHovered)
                .animation(.easeInOut(duration: 0.12), value: copied)
            }
        }
        .contentShape(Rectangle())
        .onHover { isMessageHovered = $0 }
    }
}

/// 思考步骤：默认两行预览，点击展开全文——过程信息不抢正文的视觉主体。
/// 用点击手势而非 Button，保住 textSelection 的复制能力。
private struct ThoughtStep: View {
    let id: UUID
    let text: String
    var chrome: TranscriptChromeState
    var connectAbove: Bool = false
    var connectBelow: Bool = false
    @State private var isHovered = false

    private var isExpanded: Bool {
        chrome.thoughtExpanded.contains(id)
    }

    var body: some View {
        // 参考图：思考是旁白，不是和工具同级的时间线节点——无 chevron、无竖线。
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .frame(width: 14, height: 14)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineSpacing(3)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(isHovered ? 0.9 : 1)
        .onTapGesture {
            if isExpanded {
                chrome.thoughtExpanded.remove(id)
            } else {
                chrome.thoughtExpanded.insert(id)
            }
        }
        .onHover { isHovered = $0 }
        .help(isExpanded ? "收起思考".localized : "展开完整思考".localized)
    }
}

/// 活动时间线：只在图标上下画线段，图标本身留空，避免整条贯穿穿模。
struct ActivityTimelineSegments: View {
    var connectAbove: Bool
    var connectBelow: Bool
    var iconTop: CGFloat
    var iconSize: CGFloat
    private let lineColor = Color.secondary.opacity(0.22)

    var body: some View {
        if connectAbove || connectBelow {
            GeometryReader { geo in
                let x = iconSize / 2
                let iconBottom = iconTop + iconSize
                ZStack(alignment: .topLeading) {
                    if connectAbove, iconTop > 0 {
                        Rectangle()
                            .fill(lineColor)
                            .frame(width: 1, height: iconTop)
                            .offset(x: x - 0.5, y: 0)
                    }
                    if connectBelow {
                        let h = max(0, geo.size.height - iconBottom)
                        Rectangle()
                            .fill(lineColor)
                            .frame(width: 1, height: h)
                            .offset(x: x - 0.5, y: iconBottom)
                    }
                }
            }
            .frame(width: iconSize)
            .allowsHitTesting(false)
        }
    }
}

private struct ActivityCard: View {
    let blockID: UUID
    let steps: [ActivityStep]
    var isLive: Bool
    var run: ActivityRun?
    var chrome: TranscriptChromeState
    // 运行中默认展开，让人看到工作流进展（思考全文与工具详情仍各自收起）；
    // 完成后自动收纳成摘要行，与正文做层次隔离。用户手动切换优先于默认。
    private var isExpanded: Bool {
        chrome.activityExpanded[blockID] ?? isLive
    }

    private var openCallID: UUID? {
        chrome.openToolID[blockID]
    }

    private var toolCalls: [ActivityTool] {
        steps.flatMap { step -> [ActivityTool] in
            if case .tools(_, let calls) = step { return calls }
            return []
        }
    }

    private var isBusy: Bool {
        isLive || toolCalls.contains { tool in
            !ChatSession.terminalToolStatuses.contains(tool.call.status.lowercased())
        }
    }

    private var failedCount: Int {
        toolCalls.filter { ["failed", "error"].contains($0.call.status.lowercased()) }.count
    }

    private var thoughtCount: Int {
        steps.reduce(0) { count, step in
            if case .thought = step { return count + 1 }
            return count
        }
    }

    var body: some View {
        // B：活动块不再套 material 卡片。折叠就是一行摘要；展开后内容左缩进，
        // 进行中仍用系统 ProgressView，和工具行同一套原生转圈。
        VStack(alignment: .leading, spacing: 6) {
            Button {
                chrome.activityExpanded[blockID] = !isExpanded
            } label: {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: failedCount > 0 ? "xmark.circle" : "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(failedCount > 0 ? Color.red : Palette.moss)
                    }
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // B：扁平化叶子行后按位画时间线——线段只在图标上下，中间留空不穿模。
                // spacing 为 0，让相邻行的上下线段在边界相接。
                let leaves = timelineLeaves
                // 时间线只串工具行；思考旁白不进竖线，避免和工具抢同一套节点感。
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(leaves.enumerated()), id: \.element.id) { index, leaf in
                        let isTool = { if case .tool = leaf { return true }; return false }()
                        let prevTool = index > 0 && {
                            if case .tool = leaves[index - 1] { return true }; return false
                        }()
                        let nextTool = index + 1 < leaves.count && {
                            if case .tool = leaves[index + 1] { return true }; return false
                        }()
                        leafView(
                            leaf,
                            connectAbove: isTool && prevTool,
                            connectBelow: isTool && nextTool
                        )
                    }
                }
                .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isLive) {
            // 回合结束统一收纳：运行中手动展开过的也一并收起。
            if !isLive {
                chrome.activityExpanded[blockID] = nil
                chrome.openToolID[blockID] = nil
            }
        }
    }

    private var summary: String {
        let tools = toolCalls.count
        if isBusy {
            if tools > 0 { return "正在思考并使用工具".localized }
            return "正在思考".localized
        }
        // 参考图式摘要：按动作类型聚合成「已读取文件 · 已运行命令」，少报次数。
        var parts: [String] = []
        let layouts = Set(toolCalls.map(\.call.cardLayout))
        if layouts.contains(.edit) { parts.append("已编辑文件".localized) }
        if layouts.contains(.file) { parts.append("已读取文件".localized) }
        if layouts.contains(.command) { parts.append("已运行命令".localized) }
        if layouts.contains(.search) { parts.append("已搜索".localized) }
        if layouts.contains(.fetch) { parts.append("已抓取".localized) }
        if parts.isEmpty, thoughtCount > 0 { parts.append("已思考".localized) }
        if parts.isEmpty, tools > 0 { parts.append("执行工具 %lld 次".localized(tools)) }
        if failedCount > 0 { parts.append("%lld 失败".localized(failedCount)) }
        if let duration = durationText { parts.append(duration) }
        if parts.isEmpty { return "工作记录".localized }
        return parts.joined(separator: "")
    }

    private var durationText: String? {
        guard let run else { return nil }
        let seconds = Int((run.endedAt ?? Date()).timeIntervalSince(run.startedAt))
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m\(seconds % 60)s"
    }

    private enum TimelineLeaf: Identifiable {
        case thought(id: UUID, text: String)
        case tool(ActivityTool)
        case planEntry(id: String, content: String, status: String)

        var id: String {
            switch self {
            case .thought(let id, _): return "t-\(id.uuidString)"
            case .tool(let tool): return "c-\(tool.id.uuidString)"
            case .planEntry(let id, _, _): return "p-\(id)"
            }
        }
    }

    private var timelineLeaves: [TimelineLeaf] {
        var leaves: [TimelineLeaf] = []
        for step in steps {
            switch step {
            case .thought(let id, let text):
                leaves.append(.thought(id: id, text: text))
            case .tools(_, let tools):
                for tool in tools {
                    leaves.append(.tool(tool))
                }
            case .plan(let planID, let entries):
                for (offset, entry) in entries.enumerated() {
                    leaves.append(.planEntry(
                        id: "\(planID.uuidString)-\(offset)",
                        content: entry.content,
                        status: entry.status
                    ))
                }
            }
        }
        return leaves
    }

    @ViewBuilder
    private func leafView(_ leaf: TimelineLeaf, connectAbove: Bool, connectBelow: Bool) -> some View {
        switch leaf {
        case .thought(let id, let text):
            ThoughtStep(
                id: id,
                text: text,
                chrome: chrome,
                connectAbove: connectAbove,
                connectBelow: connectBelow
            )
        case .tool(let tool):
            ToolCompactRow(
                call: tool.call,
                isOpen: openCallID == tool.id,
                connectAbove: connectAbove,
                connectBelow: connectBelow
            ) {
                chrome.openToolID[blockID] = openCallID == tool.id ? nil : tool.id
            }
        case .planEntry(_, let content, let status):
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: status == "completed" ? "checkmark.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(status == "completed" ? Palette.moss : Color.secondary.opacity(0.55))
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                Text(content)
                    .font(.system(size: 12))
                    .foregroundStyle(status == "completed" ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .overlay(alignment: .topLeading) {
                ActivityTimelineSegments(
                    connectAbove: connectAbove,
                    connectBelow: connectBelow,
                    iconTop: 5,
                    iconSize: 14
                )
            }
        }
    }
}

