import AppKit
import Foundation
import SwiftUI

struct FileOpRecord: Identifiable, Sendable, Equatable {
    let id = UUID()
    let type: String
    let path: String
    let timestamp = Date()

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case review = "审查"
    case terminal = "终端"
    case logs = "日志"
    case files = "文件"
    case info = "信息"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .review: return "doc.badge.gearshape"
        case .terminal: return "terminal"
        case .logs: return "list.bullet.rectangle"
        case .files: return "folder"
        case .info: return "info.circle"
        }
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
    let createdAt = Date()
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
    var connection: ACPConnection?
    var lastError: String?
    var phase: SessionPhase = .connecting
    var transcriptRevision = 0
    var promptTask: Task<Void, Never>?
    var isClosed = false

    init(agent: AgentProfile, cwd: String) {
        self.agent = agent
        self.cwd = cwd
        self.title = "新 \(agent.title) 对话"
    }

    func appendUser(_ text: String) {
        items.append(.user(UUID(), text))
        if title.hasPrefix("新 ") || title.hasPrefix("New ") {
            title = String(text.prefix(32))
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
            items.append(.status(UUID(), "Mode: \(mode)"))
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

@Observable
@MainActor
final class AppModel {
    var agents: [AgentProfile]
    var availability: [String: Bool] = [:]
    var sessions: [ChatSession] = []
    var selectedSessionID: UUID?
    var selectedAgentId: String
    var workspacePath: String
    var workspaceBranch: String? = nil
    var appearance: String {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appAppearance")
        }
    }
    var useLiquidGlass: Bool {
        didSet {
            UserDefaults.standard.set(useLiquidGlass, forKey: "appLiquidGlass")
        }
    }
    var autoApprove = false
    var inspectorOpen = false
    var selectedInspectorTab: InspectorTab = .logs
    var searchQuery = ""
    var draftPrompt = ""
    var isShowingCustomSheet = false
    var errorMessage: String?
    var customTitle = ""
    var customCommand = ""

    var colorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var selectedSession: ChatSession? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedAgent: AgentProfile {
        agents.first(where: { $0.id == selectedAgentId }) ?? agents.first!
    }

    var currentWorkspaceName: String {
        URL(fileURLWithPath: workspacePath).lastPathComponent
    }

    var userName: String {
        NSUserName()
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "workspacePath")
        let initialWorkspace = stored ?? FileManager.default.homeDirectoryForCurrentUser.path
        workspacePath = initialWorkspace
        appearance = UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
        useLiquidGlass = UserDefaults.standard.object(forKey: "appLiquidGlass") as? Bool ?? true

        let custom = (UserDefaults.standard.array(forKey: "customAgents") as? [Data] ?? [])
            .compactMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
        let allAgents = AgentCatalog.builtIn + custom
        agents = allAgents
        selectedAgentId = allAgents.first?.id ?? "grok-build"

        refreshAvailability()
        updateWorkspaceBranch()
    }

    func refreshAvailability() {
        var map: [String: Bool] = [:]
        for agent in agents {
            map[agent.id] = HostEnvironment.isAvailable(agent)
        }
        availability = map
    }

    func updateWorkspaceBranch() {
        let path = workspacePath
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty, branch != "HEAD" {
                        await MainActor.run { [weak self] in
                            if self?.workspacePath == path {
                                self?.workspaceBranch = branch
                            }
                        }
                        return
                    }
                }
            } catch {}
            await MainActor.run { [weak self] in
                if self?.workspacePath == path {
                    self?.workspaceBranch = nil
                }
            }
        }
    }

    func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        panel.prompt = "Choose Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            UserDefaults.standard.set(workspacePath, forKey: "workspacePath")
            updateWorkspaceBranch()
        }
    }

    func openWorkspaceInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspacePath)
    }

    func addCustomAgent() {
        guard let profile = AgentCatalog.custom(title: customTitle, commandLine: customCommand) else { return }
        agents.append(profile)
        persistCustomAgents()
        customTitle = ""
        customCommand = ""
        refreshAvailability()
    }

    func removeAgent(_ profile: AgentProfile) {
        guard !profile.builtIn else { return }
        agents.removeAll { $0.id == profile.id }
        persistCustomAgents()
    }

    func startNewSession(agent: AgentProfile? = nil) {
        let chosen = agent ?? selectedAgent
        startSession(chosen)
    }

    func startSession(_ profile: AgentProfile) {
        errorMessage = nil
        let session = ChatSession(agent: profile, cwd: workspacePath)
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        Task { await connect(session) }
    }

    func sendFromComposer(text: String, agent: AgentProfile? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let session = selectedSession {
            switch session.phase {
            case .connecting:
                return
            case .ready:
                session.appendUser(trimmed)
                enqueuePrompt(session, text: trimmed)
                return
            case .failed:
                session.appendUser(trimmed)
                enqueuePrompt(session, text: trimmed, reconnect: true)
                return
            }
        }

        let targetAgent = agent ?? selectedAgent
        let session = ChatSession(agent: targetAgent, cwd: workspacePath)
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        session.appendUser(trimmed)
        enqueuePrompt(session, text: trimmed, reconnect: true)
    }

    func send(_ text: String) {
        sendFromComposer(text: text)
    }

    func retry(_ session: ChatSession) {
        session.promptTask?.cancel()
        session.promptTask = nil
        session.lastError = nil
        session.phase = .connecting
        Task {
            await session.connection?.shutdown()
            session.connection = nil
            session.acpSessionId = nil
            await connect(session)
        }
    }

    func cancel() {
        guard let session = selectedSession else { return }
        session.promptTask?.cancel()
        session.promptTask = nil
        session.isStreaming = false
        session.resumePermission(.cancelled)
        guard let connection = session.connection, let acpId = session.acpSessionId else { return }
        Task { await connection.cancel(sessionId: acpId) }
    }

    func close(_ session: ChatSession) {
        session.isClosed = true
        session.promptTask?.cancel()
        session.promptTask = nil
        session.resumePermission(.cancelled)
        let connection = session.connection
        session.connection = nil
        Task { await connection?.shutdown() }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
    }

    func selectSessionByIndex(_ index: Int) {
        let flat = filteredSessions
        if index >= 0 && index < flat.count {
            selectedSessionID = flat[index].id
        }
    }

    var filteredSessions: [ChatSession] {
        if searchQuery.isEmpty {
            return sessions
        }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.agent.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.cwd.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var groupedSessions: [(workspaceName: String, workspacePath: String, sessions: [ChatSession])] {
        let list = filteredSessions
        var groups: [String: [ChatSession]] = [:]
        var order: [String] = []

        // Ensure current workspace comes first if present
        let current = workspacePath
        if list.contains(where: { $0.cwd == current }) {
            order.append(current)
            groups[current] = []
        }

        for session in list {
            if groups[session.cwd] == nil {
                groups[session.cwd] = []
                if !order.contains(session.cwd) {
                    order.append(session.cwd)
                }
            }
            groups[session.cwd]?.append(session)
        }

        return order.compactMap { path in
            guard let items = groups[path], !items.isEmpty else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (workspaceName: name, workspacePath: path, sessions: items)
        }
    }

    func sessionShortcut(for session: ChatSession) -> String? {
        let all = filteredSessions
        if let idx = all.firstIndex(where: { $0.id == session.id }), idx < 9 {
            return "⌘\(idx + 1)"
        }
        return nil
    }

    func resolvePermission(_ decision: PermissionDecision) {
        let session = sessions.first(where: { $0.pendingPermission != nil || $0.permissionContinuation != nil })
        session?.resumePermission(decision)
    }

    private func connect(_ session: ChatSession) async {
        session.phase = .connecting
        session.log("Launching \(session.agent.launchLine)")
        do {
            let connection = try ACPConnection.launch(
                ACPLaunch(
                    command: session.agent.command,
                    arguments: launchArguments(for: session.agent),
                    cwd: session.cwd,
                    environment: HostEnvironment.augmented()
                ),
                handlers: handlers(for: session)
            )
            session.connection = connection
            let initResponse = try await connection.initialize()
            if let info = initResponse.agentInfo {
                session.agentInfo = [info.title ?? info.name, info.version].joined(separator: " ")
            }
            if let version = initResponse.protocolVersion, version != 1 {
                session.log("Negotiated protocol version \(version)")
            }
            if !initResponse.authMethods.isEmpty {
                let method = initResponse.authMethods[0]
                let label = method.name ?? method.id
                session.log("Authenticating with \(label)")
                do {
                    try await connection.authenticate(methodId: method.id)
                } catch {
                    throw ACPError.launch("Authentication required (\(label)): \(error.localizedDescription)")
                }
            }
            let created = try await connection.newSession(cwd: session.cwd, yolo: autoApprove)
            session.acpSessionId = created.sessionId
            session.phase = .ready
        } catch {
            session.lastError = error.localizedDescription
            session.phase = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func enqueuePrompt(_ session: ChatSession, text: String, reconnect: Bool = false) {
        session.promptTask?.cancel()
        session.promptTask = Task {
            if reconnect {
                session.phase = .connecting
                session.lastError = nil
                await session.connection?.shutdown()
                session.connection = nil
                session.acpSessionId = nil
                await connect(session)
            }
            guard !Task.isCancelled, !session.isClosed, session.phase.isReady else { return }
            await prompt(session, text: text)
        }
    }

    private func prompt(_ session: ChatSession, text: String) async {
        guard let connection = session.connection, let acpId = session.acpSessionId, session.phase.isReady else {
            return
        }
        session.isStreaming = true
        defer { session.isStreaming = false }
        do {
            let response = try await connection.prompt(sessionId: acpId, text: text)
            if let reason = response.stopReason {
                session.items.append(.status(UUID(), "Stop: \(reason)"))
            }
        } catch is CancellationError {
            session.items.append(.status(UUID(), "Stop: cancelled"))
        } catch {
            session.lastError = error.localizedDescription
            session.items.append(.status(UUID(), error.localizedDescription))
        }
    }

    private func launchArguments(for profile: AgentProfile) -> [String] {
        if autoApprove, profile.id == "grok-build" {
            return ["agent", "--always-approve", "stdio"]
        }
        return profile.arguments
    }

    private func handlers(for session: ChatSession) -> ACPHandlers {
        let bridge = SessionBridge(session: session, model: self)
        return ACPHandlers(
            onUpdate: { notification in
                await MainActor.run { bridge.session?.apply(notification) }
            },
            onPermission: { prompt in
                await MainActor.run {
                    if let tool = prompt.toolCall {
                        bridge.session?.items.append(.tool(UUID(), tool))
                    }
                }
                if await MainActor.run(body: { bridge.model?.autoApprove ?? false }) {
                    if let option = prompt.options.first(where: \.isAllow) ?? prompt.options.first {
                        return .selected(option.optionId)
                    }
                    return .cancelled
                }
                guard let session = await MainActor.run(body: { bridge.session }) else { return .cancelled }
                return await session.waitForPermission(prompt)
            },
            onLog: { line in
                await MainActor.run { bridge.session?.log(line) }
            },
            onFileOp: { type, path in
                await MainActor.run { bridge.session?.recordFileOp(type: type, path: path) }
            }
        )
    }

    private func persistCustomAgents() {
        let data = agents.filter { !$0.builtIn }.compactMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(data, forKey: "customAgents")
    }
}

private final class SessionBridge: @unchecked Sendable {
    weak var session: ChatSession?
    weak var model: AppModel?

    init(session: ChatSession, model: AppModel) {
        self.session = session
        self.model = model
    }
}
