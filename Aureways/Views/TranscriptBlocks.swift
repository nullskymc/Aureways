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
        let files = attachments.filter { $0.kind != "image" }
        return VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(images) { UserAttachmentView(attachment: $0) }
                }
            }
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
        } else {
            fileChip
        }
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

    var body: some View {
        MarkdownBody(source: markdown, isStreaming: isStreaming)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 思考步骤：默认两行预览，点击展开全文——过程信息不抢正文的视觉主体。
/// 用点击手势而非 Button，保住 textSelection 的复制能力。
private struct ThoughtStep: View {
    let id: UUID
    let text: String
    var chrome: TranscriptChromeState
    @State private var isHovered = false

    private var isExpanded: Bool {
        chrome.thoughtExpanded.contains(id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(Palette.gold)
                .frame(width: 14)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
                .padding(.top, 4)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(isHovered ? 0.92 : 1)
        .onTapGesture {
            if isExpanded {
                chrome.thoughtExpanded.remove(id)
            } else {
                chrome.thoughtExpanded.insert(id)
            }
        }
        .onHover { isHovered = $0 }
        .help(isExpanded ? "收起思考" : "展开完整思考")
    }
}

private struct ActivityCard: View {
    let blockID: UUID
    let steps: [ActivityStep]
    var isLive: Bool
    var run: ActivityRun?
    var chrome: TranscriptChromeState
    @State private var isHeaderHovered = false

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
        VStack(alignment: .leading, spacing: 8) {
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if isHeaderHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.cardHover.opacity(0.35))
                }
            }
            .onHover { isHeaderHovered = $0 }

            if isExpanded {
                Divider()
                    .overlay(Palette.splitDivider)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        stepView(step)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 内容层用 .regularMaterial，不叠玻璃——这是 docs/frontend.md 已经写明的
        // 规则，也是 Apple 的 Materials 指南：Liquid Glass 属于浮在内容之上的
        // 导航层，不该铺在列表行 / 卡片上。实测每张卡都是一层实时背景采样，
        // 滚动时 vImage 的模糊卷积占到主线程 self time 的 2%。
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
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
            if tools > 0 { return "正在思考并使用工具" }
            return "正在思考"
        }
        var parts: [String] = []
        if thoughtCount > 0 { parts.append("已思考") }
        if tools > 0 { parts.append("执行工具 \(tools) 次") }
        if failedCount > 0 { parts.append("\(failedCount) 失败") }
        if let duration = durationText { parts.append(duration) }
        if parts.isEmpty { return "工作记录" }
        return parts.joined(separator: " · ")
    }

    private var durationText: String? {
        guard let run else { return nil }
        let seconds = Int((run.endedAt ?? Date()).timeIntervalSince(run.startedAt))
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m\(seconds % 60)s"
    }

    @ViewBuilder
    private func stepView(_ step: ActivityStep) -> some View {
        switch step {
        case .thought(let id, let text):
            ThoughtStep(id: id, text: text, chrome: chrome)
        case .tools(_, let tools):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tools) { tool in
                    ToolCompactRow(call: tool.call, isOpen: openCallID == tool.id) {
                        chrome.openToolID[blockID] = openCallID == tool.id ? nil : tool.id
                    }
                }
            }
        case .plan(_, let entries):
            VStack(alignment: .leading, spacing: 5) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }
}

