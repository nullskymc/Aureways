import Foundation
import Observation
import os

struct FileOpRecord: Identifiable, Sendable, Equatable {
    let id = UUID()
    let type: String
    let path: String
    let timestamp = Date()

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// 一次活动组（思考 + 工具 + 计划）的起止时间，用于摘要行的时长展示。
struct ActivityRun: Sendable, Equatable {
    var startedAt: Date
    var endedAt: Date?
}

enum SessionTitle {
    static var placeholder: String { "新对话".localized }
    static let maxLength = 42

    static func isPlaceholder(_ title: String) -> Bool {
        title == "新对话" || title == "New Chat" || title == "新对话".localized
            || title.hasPrefix("新 ") || title.hasPrefix("New ")
    }

    static func derived(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = firstLine
        while cleaned.hasPrefix("#") || cleaned.hasPrefix(">") {
            cleaned = String(cleaned.drop(while: { $0 == "#" || $0 == ">" })).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") || cleaned.hasPrefix("• ") {
            cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.hasPrefix("`"), cleaned.hasSuffix("`"), cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return placeholder }
        if cleaned.count <= maxLength { return cleaned }
        let shortened = String(cleaned.prefix(maxLength))
        if let space = shortened.lastIndex(of: " "), space > shortened.startIndex {
            return String(shortened[..<space])
        }
        return shortened
    }
}

enum TranscriptItem: Identifiable, Equatable {
    case user(UUID, String, [TranscriptAttachment])
    case agent(UUID, String)
    case thought(UUID, String)
    case tool(UUID, ToolCallView)
    case plan(UUID, [PlanEntry])
    case status(UUID, String)

    var id: UUID {
        switch self {
        case .user(let id, _, _), .agent(let id, _), .thought(let id, _), .tool(let id, _), .plan(let id, _), .status(let id, _):
            return id
        }
    }
}

enum SessionPhase: Equatable {
    case idle
    case connecting
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@Observable
@MainActor
final class ChatSession: Identifiable {
    let id = UUID()
    let agent: AgentProfile
    let cwd: String
    let createdAt: Date
    var acpSessionId: String?
    var title: String
    private(set) var items: [TranscriptItem] = []
    private(set) var transcriptEntries: [TranscriptEntry] = []
    private(set) var transcriptEntryIDs: Set<UUID> = []
    private var transcriptEntryVersions: [UUID: UInt64] = [:]
    /// Unique growing buffer for the in-flight agent/thought/user text so each
    /// chunk is O(delta) instead of a CoW copy of the whole message.
    private let liveText = NSMutableString()
    private var liveTextOwner: UUID?
    private var toolItemIndexByCallID: [String: Int] = [:]
    private var toolEntryIndexByItemID: [UUID: Int] = [:]
    var isStreaming = false
    var pendingPermission: PermissionPrompt?
    var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?
    var pendingPlanApproval: PlanApprovalPrompt?
    var planApprovalContinuation: CheckedContinuation<PlanApprovalDecision, Never>?
    var pendingUserQuestion: UserQuestionPrompt?
    var userQuestionContinuation: CheckedContinuation<UserQuestionDecision, Never>?
    var agentInfo: String = ""
    var logs: [String] = []
    private var connectDiagnosticID: UUID?
    var fileOps: [FileOpRecord] = []
    var availableCommands: [SlashCommand] = []
    var phase: SessionPhase = .connecting
    var transcriptRevision = 0
    var promptTask: Task<Void, Never>?
    var isClosed = false
    var isReplaying = false
    var configOptions: [SessionConfigOption] = []
    var models: SessionModelState?
    /// Agent actually sent `configOptions`. Synthesized model/effort chips
    /// from the `models` field still go through `session/set_model`.
    var advertisedConfigOptions = false
    var modes: SessionModeState?
    var usage: SessionUsage?
    var reportedMcpServers: [McpServerConfig] = []
    var activityRuns: [UUID: ActivityRun] = [:]
    private var currentRunID: UUID?
    private var currentUserMessageId: String?

    /// 各 harness 表示终态的写法不一，统一在这里收敛；新增终态词时同步更新。
    static let terminalToolStatuses: Set<String> = [
        "completed", "success", "failed", "error", "cancelled", "denied", "rejected"
    ]

    var modeChoices: [SessionMode] {
        if let option = configOptions.first(where: \.isMode), !option.options.isEmpty {
            return option.options
        }
        return modes?.availableModes ?? []
    }

    var currentModeId: String? {
        if let option = configOptions.first(where: \.isMode) {
            return option.value?.stringValue
        }
        let id = modes?.currentModeId
        return id?.isEmpty == false ? id : nil
    }

    var modelOption: SessionConfigOption? {
        configOptions.first(where: \.isModel)
    }

    var thoughtLevelOption: SessionConfigOption? {
        configOptions.first(where: \.isThoughtLevel)
    }

    /// 走 Markdown 渲染的正文（只有 agent 消息；思考 / 工具输出是明文）。
    /// `MarkdownDocumentCache` 预热用这个列表。
    var markdownSources: [String] {
        items.compactMap {
            if case .agent(_, let text) = $0, !text.isEmpty { return text }
            return nil
        }
    }

    init(agent: AgentProfile, cwd: String, title: String? = nil, acpSessionId: String? = nil, createdAt: Date = Date(), phase: SessionPhase = .connecting) {
        self.agent = agent
        self.cwd = cwd
        self.createdAt = createdAt
        self.acpSessionId = acpSessionId
        self.title = title ?? SessionTitle.placeholder
        self.phase = phase
    }

    func ensureTranscriptProjection() {
        if transcriptEntries.isEmpty, !items.isEmpty {
            rebuildTranscriptProjection()
        }
    }

    func replaceTranscript(_ newItems: [TranscriptItem], runs: [UUID: ActivityRun]) {
        items = newItems
        activityRuns = runs
        resetLiveText()
        rebuildTranscriptProjection()
    }

    func appendStatus(_ text: String) {
        items.append(.status(UUID(), text))
        rebuildTranscriptProjection()
        transcriptRevision += 1
    }

    /// Handshake has no ACP progress channel. One card covers stall → error so a
    /// retry that later succeeds can drop it cleanly.
    func appendConnectRPC(method: String, json: String) {
        upsertConnectDiagnostic("\(Self.connectRPCPrefix)\(method)\n\n\(json)")
    }

    func appendConnectFailure(_ text: String) {
        upsertConnectDiagnostic(text)
    }

    func clearConnectRPC() {
        guard let id = connectDiagnosticID else { return }
        connectDiagnosticID = nil
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
        rebuildTranscriptProjection()
        transcriptRevision += 1
    }

    nonisolated static var connectRPCPrefix: String { "仍在等待 ".localized }

    private func upsertConnectDiagnostic(_ text: String) {
        if let id = connectDiagnosticID, let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = .status(id, text)
        } else {
            let id = UUID()
            connectDiagnosticID = id
            items.append(.status(id, text))
        }
        rebuildTranscriptProjection()
        transcriptRevision += 1
    }

    private func rebuildToolIndex() {
        toolItemIndexByCallID.removeAll(keepingCapacity: true)
        toolEntryIndexByItemID.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            if case .tool(_, let call) = item, !call.toolCallId.isEmpty {
                toolItemIndexByCallID[call.toolCallId] = index
            }
        }
        for (entryIndex, entry) in transcriptEntries.enumerated() {
            guard case .activity(_, let steps, _) = entry.block else { continue }
            for step in steps {
                guard case .tools(_, let tools) = step else { continue }
                for tool in tools { toolEntryIndexByItemID[tool.id] = entryIndex }
            }
        }
    }

    private static let projectionSignposter = OSSignposter(
        subsystem: "ai.aureways.client",
        category: "Projection"
    )

    private func rebuildTranscriptProjection(changedBlockID: UUID? = nil) {
        let signpostID = Self.projectionSignposter.makeSignpostID()
        let state = Self.projectionSignposter.beginInterval("TranscriptProjectionRebuild", id: signpostID)
        defer { Self.projectionSignposter.endInterval("TranscriptProjectionRebuild", state) }
        #if DEBUG
        if PerfFixture.usesLegacyProjection {
            let blocks = TranscriptBlock.group(items, runs: activityRuns)
            transcriptEntries = blocks.map { TranscriptEntry(block: $0) }
            transcriptEntryIDs = Set(transcriptEntries.map(\.id))
            rebuildToolIndex()
            PerfCounters.countProjectionRebuild()
            return
        }
        #endif
        let blocks = TranscriptBlock.group(items, runs: activityRuns, countPerformance: false)
        if let changedBlockID {
            transcriptEntryVersions[changedBlockID, default: 0] &+= 1
        }
        let liveIDs = Set(blocks.map(\.id))
        transcriptEntryIDs = liveIDs
        transcriptEntryVersions = transcriptEntryVersions.filter { liveIDs.contains($0.key) }
        let existingEntries = Dictionary(uniqueKeysWithValues: transcriptEntries.map { ($0.id, $0) })
        transcriptEntries = blocks.map { block in
            var version = transcriptEntryVersions[block.id, default: 0]
            if let entry = existingEntries[block.id] {
                if entry.block != block { version &+= 1 }
                transcriptEntryVersions[block.id] = version
                entry.block = block
                entry.version = version
                return entry
            }
            transcriptEntryVersions[block.id] = version
            return TranscriptEntry(block: block, version: version)
        }
        rebuildToolIndex()
        #if DEBUG
        PerfCounters.countProjectionRebuild()
        #endif
    }

    func appendUser(_ text: String, attachments: [TranscriptAttachment] = []) {
        currentUserMessageId = nil
        for attachment in attachments where attachment.kind == "image" {
            TranscriptImageStore.prefetch(attachment)
        }
        items.append(.user(UUID(), text, attachments))
        rebuildTranscriptProjection()
        if !isReplaying, SessionTitle.isPlaceholder(title) {
            let source = text.isEmpty ? (attachments.first?.name ?? text) : text
            title = SessionTitle.derived(from: source)
        }
        transcriptRevision += 1
    }

    func apply(_ notification: SessionNotification) {
        var visual = false
        var projectionUpdated = false
        switch notification.update {
        case .agentMessageChunk(let content):
            currentUserMessageId = nil
            noteLiveText(
                appendAgentContent(content),
                asThought: false,
                visual: &visual,
                projectionUpdated: &projectionUpdated
            )
        case .agentThoughtChunk(let content):
            noteLiveText(
                appendText(content.text ?? "", asThought: true),
                asThought: true,
                visual: &visual,
                projectionUpdated: &projectionUpdated
            )
        case .userMessageChunk(let content):
            noteUserChunk(
                applyUserChunk(content, messageId: notification.messageId),
                visual: &visual,
                projectionUpdated: &projectionUpdated
            )
        case .toolCall(let call):
            currentUserMessageId = nil
            appendTool(call, incrementsRevision: false)
            projectionUpdated = true
            visual = true
        case .toolCallUpdate(let call):
            currentUserMessageId = nil
            let index: Int?
            if !call.toolCallId.isEmpty, let mapped = toolItemIndexByCallID[call.toolCallId] {
                index = mapped
            } else {
                index = items.lastIndex(where: {
                    if case .tool(_, let existing) = $0 { return existing.toolCallId == call.toolCallId }
                    return false
                })
            }
            if let index, case .tool(let id, var existing) = items[index] {
                guard existing.merge(call) else { return }
                items[index] = .tool(id, existing)
                if !updateProjectedTool(itemID: id, call: existing) {
                    rebuildTranscriptProjection(changedBlockID: transcriptBlockID(containingItemID: id))
                }
                projectionUpdated = true
            } else {
                appendTool(call, incrementsRevision: false)
                projectionUpdated = true
            }
            visual = true
        case .plan(let entries):
            currentUserMessageId = nil
            if let index = items.lastIndex(where: { if case .plan = $0 { return true }; return false }) {
                if case .plan(let id, _) = items[index] {
                    items[index] = .plan(id, entries)
                }
            } else {
                let id = UUID()
                beginRun(id)
                items.append(.plan(id, entries))
            }
            visual = true
        case .availableCommands(let commands):
            availableCommands = commands
        case .sessionInfo(let title) where !title.isEmpty:
            self.title = title
        case .currentMode(let mode) where !mode.isEmpty:
            if var modes {
                modes.currentModeId = mode
                self.modes = modes
            }
            if let index = configOptions.firstIndex(where: \.isMode) {
                configOptions[index].value = .string(mode)
            }
            if !isReplaying {
                items.append(.status(UUID(), "Mode: \(mode)"))
                visual = true
            }
        case .configOptions(let options) where !options.isEmpty:
            configOptions = options
        case .configOption(let id, let value) where !id.isEmpty:
            applyConfigOption(id: id, value: value)
        case .modelChanged(let modelId, let effort):
            applyModelChange(modelId: modelId.isEmpty ? nil : modelId, effort: effort)
        case .usage(let usage):
            self.usage = usage
        default:
            break
        }
        if visual {
            if !projectionUpdated {
                rebuildTranscriptProjection()
            }
            transcriptRevision += 1
        }
    }

    /// Agent 图片不要把 base64 写进 Markdown：流式重解析会把整段历史拖垮。
    private func appendAgentContent(_ content: ContentBlock) -> LiveTextApply {
        switch content {
        case .image(_, _, let uri):
            if let uri, !uri.isEmpty {
                let name = URL(string: uri)?.lastPathComponent ?? "image"
                return appendText("\n\n![\(name)](\(uri))\n\n", asThought: false)
            }
            return appendText("\n\n" + "(图片)".localized + "\n\n", asThought: false)
        case .resourceLink(let uri, let name):
            return appendText("[\(name)](\(uri))", asThought: false)
        case .resource(let uri, _, let text, _):
            if let text, !text.isEmpty {
                return appendText(text, asThought: false)
            }
            if !uri.isEmpty {
                return appendText(uri, asThought: false)
            }
            return .ignored
        case .audio:
            return appendText("\n\n" + "(音频)".localized + "\n\n", asThought: false)
        case .text(let value):
            return appendText(value, asThought: false)
        case .other:
            return appendText(content.text ?? "", asThought: false)
        }
    }

    func waitForPermission(_ prompt: PermissionPrompt) async -> PermissionDecision {
        if isClosed { return .cancelled }
        resumePermission(.cancelled)
        pendingPermission = prompt
        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    func resumePermission(_ decision: PermissionDecision) {
        if isDenial(decision), let toolCallId = pendingPermission?.toolCall?.toolCallId {
            markToolCallCancelled(toolCallId)
        }
        pendingPermission = nil
        let waiter = permissionContinuation
        permissionContinuation = nil
        waiter?.resume(returning: decision)
    }

    func resumeBlockingPrompts() {
        resumePermission(.cancelled)
        resumePlanApproval(.quit)
        resumeUserQuestion(.chatAboutThis)
    }

    func waitForPlanApproval(_ prompt: PlanApprovalPrompt) async -> PlanApprovalDecision {
        if isClosed { return .quit }
        resumePlanApproval(.quit)
        pendingPlanApproval = prompt
        return await withCheckedContinuation { continuation in
            planApprovalContinuation = continuation
        }
    }

    func resumePlanApproval(_ decision: PlanApprovalDecision) {
        pendingPlanApproval = nil
        let waiter = planApprovalContinuation
        planApprovalContinuation = nil
        waiter?.resume(returning: decision)
    }

    func waitForUserQuestion(_ prompt: UserQuestionPrompt) async -> UserQuestionDecision {
        if isClosed { return .chatAboutThis }
        resumeUserQuestion(.chatAboutThis)
        pendingUserQuestion = prompt
        return await withCheckedContinuation { continuation in
            userQuestionContinuation = continuation
        }
    }

    func resumeUserQuestion(_ decision: UserQuestionDecision) {
        pendingUserQuestion = nil
        let waiter = userQuestionContinuation
        userQuestionContinuation = nil
        waiter?.resume(returning: decision)
    }

    private func isDenial(_ decision: PermissionDecision) -> Bool {
        switch decision {
        case .cancelled:
            return true
        case .selected(let optionId):
            guard let option = pendingPermission?.options.first(where: { $0.optionId == optionId }) else { return false }
            return !option.isAllow
        }
    }

    private func markToolCallCancelled(_ toolCallId: String) {
        guard let index = items.lastIndex(where: {
            if case .tool(_, let call) = $0 { return call.toolCallId == toolCallId }
            return false
        }), case .tool(let id, var call) = items[index] else { return }
        guard !Self.terminalToolStatuses.contains(call.status.lowercased()) else { return }
        call.status = "cancelled"
        items[index] = .tool(id, call)
        if !updateProjectedTool(itemID: id, call: call) {
            rebuildTranscriptProjection(changedBlockID: transcriptBlockID(containingItemID: id))
        }
        transcriptRevision += 1
    }

    private func updateProjectedTool(itemID: UUID, call: ToolCallView) -> Bool {
        #if DEBUG
        if PerfFixture.usesLegacyProjection { return false }
        #endif
        guard let entryIndex = toolEntryIndexByItemID[itemID],
              transcriptEntries.indices.contains(entryIndex),
              case .activity(let blockID, var steps, let run) = transcriptEntries[entryIndex].block
        else { return false }

        for stepIndex in steps.indices {
            guard case .tools(let toolsID, var tools) = steps[stepIndex],
                  let toolIndex = tools.firstIndex(where: { $0.id == itemID })
            else { continue }
            tools[toolIndex].call = call
            steps[stepIndex] = .tools(toolsID, tools)
            let entry = transcriptEntries[entryIndex]
            entry.block = .activity(blockID, steps, run)
            entry.version &+= 1
            transcriptEntryVersions[blockID] = entry.version
            #if DEBUG
            PerfCounters.countProjectionUpdate()
            #endif
            return true
        }
        return false
    }

    private enum LiveTextApply {
        case ignored
        case created
        case continued(id: UUID, text: String)
    }

    private enum UserChunkApply {
        case ignored
        case created
        case continued(id: UUID, text: String, attachments: [TranscriptAttachment])
    }

    private func noteLiveText(
        _ result: LiveTextApply,
        asThought: Bool,
        visual: inout Bool,
        projectionUpdated: inout Bool
    ) {
        switch result {
        case .ignored:
            break
        case .created:
            visual = true
        case .continued(let id, let text):
            visual = true
            if updateProjectedLiveText(itemID: id, text: text, asThought: asThought) {
                projectionUpdated = true
            }
        }
    }

    private func noteUserChunk(
        _ result: UserChunkApply,
        visual: inout Bool,
        projectionUpdated: inout Bool
    ) {
        switch result {
        case .ignored:
            break
        case .created:
            visual = true
        case .continued(let id, let text, let attachments):
            visual = true
            if updateProjectedUser(itemID: id, text: text, attachments: attachments) {
                projectionUpdated = true
            }
        }
    }

    private func updateProjectedLiveText(itemID: UUID, text: String, asThought: Bool) -> Bool {
        #if DEBUG
        if PerfFixture.usesLegacyProjection { return false }
        #endif
        guard let last = transcriptEntries.last else { return false }
        if asThought {
            guard case .activity(let blockID, var steps, let run) = last.block,
                  let stepIndex = steps.lastIndex(where: {
                      if case .thought(let id, _) = $0 { return id == itemID }
                      return false
                  })
            else { return false }
            steps[stepIndex] = .thought(itemID, text)
            last.block = .activity(blockID, steps, run)
            last.version &+= 1
            transcriptEntryVersions[blockID] = last.version
        } else {
            guard case .agent(let id, _) = last.block, id == itemID else { return false }
            last.block = .agent(id, text)
            last.version &+= 1
            transcriptEntryVersions[id] = last.version
        }
        #if DEBUG
        PerfCounters.countProjectionUpdate()
        #endif
        return true
    }

    private func updateProjectedUser(
        itemID: UUID,
        text: String,
        attachments: [TranscriptAttachment]
    ) -> Bool {
        #if DEBUG
        if PerfFixture.usesLegacyProjection { return false }
        #endif
        guard let last = transcriptEntries.last,
              case .user(let id, _, _) = last.block,
              id == itemID
        else { return false }
        last.block = .user(id, text, attachments)
        last.version &+= 1
        transcriptEntryVersions[id] = last.version
        #if DEBUG
        PerfCounters.countProjectionUpdate()
        #endif
        return true
    }

    private func transcriptBlockID(containingItemID itemID: UUID) -> UUID? {
        for entry in transcriptEntries {
            switch entry.block {
            case .activity(let id, let steps, _):
                for step in steps {
                    if case .tools(_, let tools) = step, tools.contains(where: { $0.id == itemID }) {
                        return id
                    }
                }
            default:
                if entry.id == itemID { return entry.id }
            }
        }
        return nil
    }

    func appendTool(_ call: ToolCallView, incrementsRevision: Bool = true) {
        let id = UUID()
        beginRun(id)
        items.append(.tool(id, call))
        rebuildTranscriptProjection()
        if incrementsRevision { transcriptRevision += 1 }
    }

    private func beginRun(_ id: UUID) {
        guard currentRunID == nil else { return }
        currentRunID = id
        activityRuns[id] = ActivityRun(startedAt: Date())
    }

    func endCurrentRun() {
        guard let id = currentRunID else { return }
        if activityRuns[id]?.endedAt == nil {
            activityRuns[id]?.endedAt = Date()
        }
        currentRunID = nil
    }

    /// prompt 回合结束后兜底：harness 可能不再补发工具终态，
    /// 未收尾的调用按给定状态关闭，避免摘要行永久转圈。
    func finalizeOpenToolCalls(_ status: String) {
        endCurrentRun()
        var changed = false
        for index in items.indices {
            guard case .tool(let id, var call) = items[index] else { continue }
            guard !Self.terminalToolStatuses.contains(call.status.lowercased()) else { continue }
            call.status = status
            items[index] = .tool(id, call)
            changed = true
        }
        if changed {
            rebuildTranscriptProjection()
            transcriptRevision += 1
        }
    }

    func applySetup(
        sessionId: String,
        modes: SessionModeState?,
        configOptions: [SessionConfigOption],
        models: SessionModelState? = nil,
        advertisedConfigOptions: Bool = false,
        mcpServers: [McpServerConfig] = []
    ) {
        acpSessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
        self.models = models
        self.advertisedConfigOptions = advertisedConfigOptions
        if !mcpServers.isEmpty {
            reportedMcpServers = mcpServers
        }
    }

    func applyConfigOption(id: String, value: JSONValue) {
        guard let index = configOptions.firstIndex(where: { $0.id == id }) else { return }
        let option = configOptions[index]
        configOptions[index].value = SessionConfigOption.scalarValue(value) ?? value
        if option.isModel, let modelId = configOptions[index].selectedString {
            syncThoughtLevel(to: modelId, preserving: thoughtLevelOption?.selectedString)
        }
    }

    func applyModelChange(modelId: String?, effort: String?) {
        if let modelId, !modelId.isEmpty {
            if let index = configOptions.firstIndex(where: \.isModel) {
                configOptions[index].value = .string(modelId)
            }
            syncThoughtLevel(to: modelId, preserving: effort ?? thoughtLevelOption?.selectedString)
        } else if let effort, let index = configOptions.firstIndex(where: \.isThoughtLevel) {
            configOptions[index].value = .string(effort)
        }
    }

    func syncThoughtLevel(to modelId: String, preserving effort: String? = nil) {
        if var models {
            models.select(modelId)
            self.models = models
        }
        guard let model = models?.availableModels.first(where: { $0.id == modelId })
                ?? models?.current else { return }
        if let thought = SessionConfigOption.thoughtLevel(from: model, preserving: effort) {
            if let index = configOptions.firstIndex(where: \.isThoughtLevel) {
                configOptions[index] = thought
            } else {
                configOptions.append(thought)
            }
        } else if let index = configOptions.firstIndex(where: \.isThoughtLevel) {
            configOptions.remove(at: index)
        }
    }

    func replaceConfigOptions(_ options: [SessionConfigOption]) {
        guard !options.isEmpty else { return }
        configOptions = options
    }

    func resetTranscript() {
        items = []
        connectDiagnosticID = nil
        logs = []
        fileOps = []
        availableCommands = []
        activityRuns = [:]
        currentRunID = nil
        currentUserMessageId = nil
        usage = nil
        reportedMcpServers = []
        transcriptEntryVersions.removeAll()
        transcriptEntryIDs.removeAll()
        resetLiveText()
        rebuildTranscriptProjection()
        transcriptRevision += 1
    }

    private func resetLiveText() {
        liveText.setString("")
        liveTextOwner = nil
    }

    private func snapshotLiveText() -> String {
        String(liveText)
    }

    private func appendLiveText(_ text: String, owner: UUID, existing: String) {
        if liveTextOwner != owner {
            liveText.setString(existing)
            liveTextOwner = owner
        }
        liveText.append(text)
    }

    /// ACP chunks are usually deltas. Some harnesses (and retries) resend the
    /// whole buffer; treating those as deltas duplicates the last paragraphs.
    /// Returns nil when the live buffer did not change.
    private func mergeLiveText(existing: String, chunk: String, owner: UUID) -> String? {
        if chunk == existing || existing.hasPrefix(chunk) {
            return nil
        }
        if chunk.hasPrefix(existing) {
            liveText.setString(chunk)
            liveTextOwner = owner
            return chunk
        }
        appendLiveText(chunk, owner: owner, existing: existing)
        return snapshotLiveText()
    }

    private func appendText(_ text: String, asThought: Bool) -> LiveTextApply {
        guard !text.isEmpty else { return .ignored }
        if asThought {
            if case .thought(let id, let existing) = items.last {
                guard let merged = mergeLiveText(existing: existing, chunk: text, owner: id) else {
                    return .ignored
                }
                items[items.count - 1] = .thought(id, merged)
                return .continued(id: id, text: merged)
            }
            let id = UUID()
            liveText.setString(text)
            liveTextOwner = id
            beginRun(id)
            items.append(.thought(id, text))
            return .created
        }
        endCurrentRun()
        if case .agent(let id, let existing) = items.last {
            guard let merged = mergeLiveText(existing: existing, chunk: text, owner: id) else {
                return .ignored
            }
            items[items.count - 1] = .agent(id, merged)
            return .continued(id: id, text: merged)
        }
        let id = UUID()
        liveText.setString(text)
        liveTextOwner = id
        items.append(.agent(id, text))
        return .created
    }

    @discardableResult
    private func applyUserChunk(_ content: ContentBlock, messageId: String? = nil) -> UserChunkApply {
        endCurrentRun()

        let fromBlock = TranscriptAttachment(contentBlock: content)
        // Image / file / paste drafts are attachments. Overflow `text` is the
        // original paste we sent — the composer card exists so history does not
        // typeset that payload. Same for `resource.text` on replay of old sends.
        let rawText = fromBlock == nil ? (content.text ?? "") : ""
        let isOverflowText = fromBlock == nil && ComposerOverflow.exceedsInlineLimit(rawText)

        func isDuplicateAttachment(_ a: TranscriptAttachment, in existing: [TranscriptAttachment]) -> Bool {
            existing.contains { b in
                if let a64 = a.imageBase64, let b64 = b.imageBase64, !a64.isEmpty, !b64.isEmpty {
                    return a64 == b64
                }
                if let ap = a.path, let bp = b.path, !ap.isEmpty, !bp.isEmpty {
                    return ap == bp
                }
                return a.name == b.name && a.kind == b.kind
            }
        }

        let isSameMessage: Bool
        if let messageId, let lastId = currentUserMessageId {
            isSameMessage = (messageId == lastId)
        } else {
            if case .user = items.last {
                isSameMessage = true
            } else {
                isSameMessage = false
            }
        }

        if isOverflowText, isSameMessage, case .user(_, _, let existing) = items.last,
           existing.contains(where: \.isPastedText) {
            return .ignored
        }

        let attachment: TranscriptAttachment?
        let text: String
        if isOverflowText {
            attachment = TranscriptAttachment(
                id: UUID(),
                kind: "pastedText",
                name: "粘贴的文本".localized,
                path: nil,
                mimeType: "text/plain",
                imageBase64: nil,
                characterCount: ComposerOverflow.utf16Count(rawText)
            )
            text = ""
        } else {
            attachment = fromBlock
            text = rawText
        }

        guard !text.isEmpty || attachment != nil else { return .ignored }

        if isSameMessage, case .user(let id, let existingText, var existingAttachments) = items.last {
            if let messageId {
                currentUserMessageId = messageId
            }
            var updatedText = existingText
            var changed = false
            if !text.isEmpty {
                if let merged = mergeLiveText(existing: existingText, chunk: text, owner: id) {
                    updatedText = merged
                    changed = true
                } else if existingText.isEmpty {
                    liveText.setString(text)
                    liveTextOwner = id
                    updatedText = text
                    changed = true
                }
            }
            if let attachment, !isDuplicateAttachment(attachment, in: existingAttachments) {
                if attachment.kind == "image" { TranscriptImageStore.prefetch(attachment) }
                existingAttachments.append(attachment)
                changed = true
            }
            if !isReplaying, SessionTitle.isPlaceholder(title) {
                let source = text.isEmpty ? (attachment?.name ?? text) : text
                if !source.isEmpty {
                    title = SessionTitle.derived(from: source)
                }
            }
            guard changed else { return .ignored }
            items[items.count - 1] = .user(id, updatedText, existingAttachments)
            return .continued(id: id, text: updatedText, attachments: existingAttachments)
        }

        if let messageId {
            currentUserMessageId = messageId
        }
        let attachments = attachment.map { [$0] } ?? []
        let id = UUID()
        if !text.isEmpty {
            liveText.setString(text)
            liveTextOwner = id
        }
        items.append(.user(id, text, attachments))

        if !isReplaying, SessionTitle.isPlaceholder(title) {
            let source = text.isEmpty ? (attachment?.name ?? text) : text
            if !source.isEmpty {
                title = SessionTitle.derived(from: source)
            }
        }
        return .created
    }

    private func coalesceUser(_ text: String) {
        applyUserChunk(.text(text))
    }

    func log(_ line: String) {
        logs.append(line)
        if logs.count > 400 {
            logs.removeFirst(logs.count - 400)
        }
    }

    func recordFileOp(type: String, path: String) {
        fileOps.insert(FileOpRecord(type: type, path: path), at: 0)
        if fileOps.count > 100 {
            fileOps.removeLast(fileOps.count - 100)
        }
    }
}
