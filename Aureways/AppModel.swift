import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
final class AppModel {
    static weak var shared: AppModel?

    var agents: [AgentProfile]
    var availability: [String: Bool] = [:]
    var disabledAgentIds: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(disabledAgentIds), forKey: "disabledAgentIds")
        }
    }
    var sessions: [ChatSession] = []
    var selectedSessionID: UUID?
    var selectedAgentId: String {
        didSet {
            if oldValue != selectedAgentId {
                UserDefaults.standard.set(selectedAgentId, forKey: "selectedAgentId")
            }
        }
    }
    var workspacePath: String
    var workspaces: [WorkspaceRecord] = []
    var workspaceBranch: String? = nil
    var appearance: String {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appAppearance")
        }
    }
    var autoApprove = false
    var inspectorOpen = false
    var paneTabs: [PaneTab] = [.browser]
    var activePaneTabId = PaneTab.browser.id
    var fileTabStates: [String: FileTabState] = [:]
    var interactiveTerminals: [UUID: InteractiveTerminal] = [:]
    var browserInvalidationToken = 0
    var pendingSavePath: String?
    var pendingSaveContent: String?
    var pendingClosePath: String?
    var pendingReloadPath: String?
    var editorDrafts: [String: String] = [:]
    var terminalTitles: [UUID: String] = [:]
    var searchQuery = ""
    var draftPrompt = ""
    var fileIndex = WorkspaceFileIndex()
    var errorMessage: String?
    var customTitle = ""
    var customCommand = ""
    var mcpServers: [McpServerConfig] = [] {
        didSet { persistMcpServers() }
    }

    var runtimes: [String: HarnessRuntime] = [:]
    let store: SessionStore?
    let sessionUpdateInbox = SessionUpdateInbox()
    var sessionUpdatePulse: DisplayPulse?

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

    /// 新建对话可选的 harness：停用的不出现。
    var selectableAgents: [AgentProfile] {
        agents.filter { !disabledAgentIds.contains($0.id) }
    }

    func isAgentEnabled(_ agent: AgentProfile) -> Bool {
        !disabledAgentIds.contains(agent.id)
    }

    func setAgentEnabled(_ agent: AgentProfile, enabled: Bool) {
        if enabled {
            disabledAgentIds.remove(agent.id)
        } else {
            disabledAgentIds.insert(agent.id)
            if selectedAgentId == agent.id, let fallback = selectableAgents.first {
                selectedAgentId = fallback.id
            }
        }
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
        disabledAgentIds = Set(UserDefaults.standard.stringArray(forKey: "disabledAgentIds") ?? [])

        let custom = (UserDefaults.standard.array(forKey: "customAgents") as? [Data] ?? [])
            .compactMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
        let allAgents = AgentCatalog.builtIn + custom
        agents = allAgents
        let storedAgent = UserDefaults.standard.string(forKey: "selectedAgentId").map(HarnessRegistry.migrateAgentId)
        selectedAgentId = allAgents.first(where: { $0.id == storedAgent })?.id ?? allAgents.first?.id ?? GrokBuildHarness.id
        if UserDefaults.standard.string(forKey: "selectedAgentId") == "gemini" {
            UserDefaults.standard.set(AntigravityHarness.id, forKey: "selectedAgentId")
        }
        store = try? SessionStore.applicationDefault()
        mcpServers = Self.loadMcpServers()

        if let store, let cached = try? store.list() {
            var seenIDs = Set<String>()
            sessions = cached.compactMap { link in
                let idKey = "\(link.agentId)|\(link.acpSessionId)"
                guard seenIDs.insert(idKey).inserted else { return nil }
                guard let agent = allAgents.first(where: { $0.id == link.agentId }) else { return nil }
                return ChatSession(
                    agent: agent,
                    cwd: link.cwd,
                    title: link.title,
                    acpSessionId: link.acpSessionId,
                    createdAt: link.createdAt,
                    phase: .idle
                )
            }
        }

        refreshAvailability()
        bootstrapWorkspaces(currentPath: initialWorkspace)
        updateWorkspaceBranch()
        #if DEBUG
        installPerfFixtureIfRequested()
        #endif
        AppModel.shared = self
    }

    func refreshAvailability() {
        var map: [String: Bool] = [:]
        for agent in agents {
            map[agent.id] = HostEnvironment.isAvailable(agent)
        }
        availability = map
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

    func persistCustomAgents() {
        let data = agents.filter { !$0.builtIn }.compactMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(data, forKey: "customAgents")
    }

    func persistMcpServers() {
        if let data = try? JSONEncoder().encode(mcpServers) {
            UserDefaults.standard.set(data, forKey: "mcpServers")
        }
    }

    static func loadMcpServers() -> [McpServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: "mcpServers") else { return [] }
        return (try? JSONDecoder().decode([McpServerConfig].self, from: data)) ?? []
    }

    func mcpPayload(for capabilities: AgentCapabilities) -> [JSONValue] {
        mcpServers.compactMap { $0.json(capabilities: capabilities.mcpCapabilities) }
    }

    func extraWorkspaceRoots(besides cwd: String) -> [String] {
        var seen = Set<String>([cwd])
        var roots: [String] = []
        for workspace in workspaces {
            let path = workspace.path
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            roots.append(path)
        }
        return roots
    }

    func additionalDirectories(for runtime: HarnessRuntime, cwd: String) -> [String] {
        guard runtime.capabilities.canAdditionalDirectories else { return [] }
        return extraWorkspaceRoots(besides: cwd)
    }

    #if DEBUG
    /// Adds a pre-filled, agent-free session so scrolling can be traced against
    /// a fixed transcript. No-op unless `AUREWAYS_PERF_TURNS` is set.
    /// See `PerfFixture` for the shape of the transcript.
    func installPerfFixtureIfRequested() {
        guard let turns = PerfFixture.requestedTurns, let agent = agents.first else { return }
        let session = ChatSession(
            agent: agent,
            cwd: workspacePath,
            title: "Perf fixture · \(turns) turns",
            phase: .ready
        )
        session.items = PerfFixture.items(turns: turns)
        session.activityRuns = PerfFixture.runs(for: session.items)
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        NSLog("[perf] fixture session: %d turns, %d items", turns, session.items.count)
    }
    #endif
}
