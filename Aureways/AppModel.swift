import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
final class AppModel {
    var agents: [AgentProfile]
    var availability: [String: Bool] = [:]
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
    var selectedInspectorTab: InspectorTab = .logs
    var searchQuery = ""
    var draftPrompt = ""
    var errorMessage: String?
    var customTitle = ""
    var customCommand = ""

    var runtimes: [String: HarnessRuntime] = [:]
    let store: SessionStore?

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
}
