import Foundation
import Observation

struct FileOpRecord: Identifiable, Sendable, Equatable {
    let id = UUID()
    let type: String
    let path: String
    let timestamp = Date()

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum SessionTitle {
    static let placeholder = "新对话"
    static let maxLength = 42

    static func isPlaceholder(_ title: String) -> Bool {
        title == placeholder || title.hasPrefix("新 ") || title.hasPrefix("New ")
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
    case user(UUID, String)
    case agent(UUID, String)
    case thought(UUID, String)
    case tool(UUID, ToolCallView)
    case plan(UUID, [PlanEntry])
    case status(UUID, String)

    var id: UUID {
        switch self {
        case .user(let id, _), .agent(let id, _), .thought(let id, _), .tool(let id, _), .plan(let id, _), .status(let id, _):
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
    var items: [TranscriptItem] = []
    var isStreaming = false
    var pendingPermission: PermissionPrompt?
    var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?
    var agentInfo: String = ""
    var logs: [String] = []
    var fileOps: [FileOpRecord] = []
    var availableCommands: [SlashCommand] = []
    var phase: SessionPhase = .connecting
    var transcriptRevision = 0
    var promptTask: Task<Void, Never>?
    var isClosed = false
    var isReplaying = false
    var configOptions: [SessionConfigOption] = []
    var modes: SessionModeState?

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

    init(agent: AgentProfile, cwd: String, title: String? = nil, acpSessionId: String? = nil, createdAt: Date = Date(), phase: SessionPhase = .connecting) {
        self.agent = agent
        self.cwd = cwd
        self.createdAt = createdAt
        self.acpSessionId = acpSessionId
        self.title = title ?? SessionTitle.placeholder
        self.phase = phase
    }

    func appendUser(_ text: String) {
        items.append(.user(UUID(), text))
        if !isReplaying, SessionTitle.isPlaceholder(title) {
            title = SessionTitle.derived(from: text)
        }
        transcriptRevision += 1
    }

    func apply(_ notification: SessionNotification) {
        switch notification.update {
        case .agentMessageChunk(let content):
            appendText(content.text ?? "", asThought: false)
        case .agentThoughtChunk(let content):
            appendText(content.text ?? "", asThought: true)
        case .userMessageChunk(let content):
            coalesceUser(content.text ?? "")
        case .toolCall(let call):
            items.append(.tool(UUID(), call))
        case .toolCallUpdate(let call):
            if let index = items.lastIndex(where: {
                if case .tool(_, let existing) = $0 { return existing.toolCallId == call.toolCallId }
                return false
            }) {
                if case .tool(let id, var existing) = items[index] {
                    existing.merge(call)
                    items[index] = .tool(id, existing)
                }
            } else {
                items.append(.tool(UUID(), call))
            }
        case .plan(let entries):
            if let index = items.lastIndex(where: { if case .plan = $0 { return true }; return false }) {
                if case .plan(let id, _) = items[index] {
                    items[index] = .plan(id, entries)
                }
            } else {
                items.append(.plan(UUID(), entries))
            }
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
            }
        case .configOption(let id, let value) where !id.isEmpty:
            applyConfigOption(id: id, value: value)
        default:
            break
        }
        transcriptRevision += 1
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
        pendingPermission = nil
        let waiter = permissionContinuation
        permissionContinuation = nil
        waiter?.resume(returning: decision)
    }

    func applySetup(sessionId: String, modes: SessionModeState?, configOptions: [SessionConfigOption]) {
        acpSessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
    }

    func applyConfigOption(id: String, value: JSONValue) {
        if let index = configOptions.firstIndex(where: { $0.id == id }) {
            configOptions[index].value = value
        }
    }

    func resetTranscript() {
        items = []
        logs = []
        fileOps = []
        availableCommands = []
        transcriptRevision += 1
    }

    private func appendText(_ text: String, asThought: Bool) {
        guard !text.isEmpty else { return }
        if asThought {
            if case .thought(let id, let existing) = items.last {
                items[items.count - 1] = .thought(id, existing + text)
            } else {
                items.append(.thought(UUID(), text))
            }
        } else {
            if case .agent(let id, let existing) = items.last {
                items[items.count - 1] = .agent(id, existing + text)
            } else {
                items.append(.agent(UUID(), text))
            }
        }
    }

    private func coalesceUser(_ text: String) {
        guard !text.isEmpty else { return }
        if case .user(let id, let existing) = items.last {
            if text == existing || existing.hasPrefix(text) {
                return
            }
            if text.hasPrefix(existing) {
                items[items.count - 1] = .user(id, text)
            } else {
                items[items.count - 1] = .user(id, existing + text)
            }
        } else {
            items.append(.user(UUID(), text))
        }
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
