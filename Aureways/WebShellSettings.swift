import AppKit
import Foundation

/// Settings route of the web app. Every former SwiftUI Settings page lives
/// here: appearance/language/menu bar, Markdown default app, default agent,
/// agents (enable, default, custom add/remove, launch line), workspaces,
/// permissions, MCP servers, and harness quota.
extension WebShellBridge {
    static let menuBarKey = "showMenuBarExtra"

    func encodeSettings() -> [String: Any] {
        let defaults = UserDefaults.standard
        let showMenuBar = defaults.object(forKey: Self.menuBarKey) as? Bool ?? true
        var reported: [[String: Any]] = []
        var seen = Set<String>()
        for session in model.sessions where !session.isClosed {
            for server in session.reportedMcpServers where seen.insert(server.name).inserted {
                reported.append(["name": server.name, "summary": server.summary.isEmpty ? server.transport.rawValue : server.summary])
            }
        }
        var settings: [String: Any] = [
            "appearance": model.appearance,
            "language": model.appLanguage,
            "systemLanguage": L10n.systemLanguage,
            "showMenuBar": showMenuBar,
            "markdownDefault": markdownDefaultCache,
            "autoApprove": model.autoApprove,
            "defaultAgentId": model.selectedAgentId,
            "version": AppInfo.version,
            "agents": model.agents.map { agent -> [String: Any] in
                [
                    "id": agent.id,
                    "title": agent.title,
                    "subtitle": agent.subtitle,
                    "builtIn": agent.builtIn,
                    "launchLine": agent.launchLine,
                    "notes": agent.notes,
                    "enabled": model.isAgentEnabled(agent),
                    "available": model.availability[agent.id] == true,
                    "quotaRefreshing": model.quotaStore.isRefreshing[agent.id] == true,
                ]
            },
            "workspaces": model.workspaces.map { ["path": $0.path, "name": $0.name] },
            "defaultWorkspace": model.workspacePath,
            "mcpServers": model.mcpServers.map { server -> [String: Any] in
                [
                    "id": server.id.uuidString, "name": server.name, "transport": server.transport.rawValue,
                    "summary": server.summary, "enabled": server.enabled,
                ]
            },
            "reportedMcp": reported,
        ]
        if let caps = model.runtimes[model.selectedAgentId]?.capabilities.mcpCapabilities {
            settings["mcpCaps"] = ["http": caps.http, "sse": caps.sse]
        }
        return settings
    }

    func encodeQuota() -> [String: Any] {
        var out: [String: Any] = [:]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let store = model.quotaStore
        for (id, snapshot) in store.snapshots {
            guard let data = try? encoder.encode(snapshot),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            object["severity"] = snapshot.overallSeverity.rawValue
            object["summary"] = snapshot.shortSummary
            object["fetchedAt"] = snapshot.fetchedAt.timeIntervalSince1970 * 1000
            if let next = store.nextAllowedFetch(for: id) {
                object["nextRefreshAt"] = next.timeIntervalSince1970 * 1000
            }
            out[id] = object
        }
        return out
    }

    /// Returns nil when the method isn't a settings call.
    func handleSettingsRPC(_ method: String, _ params: [String: Any]) -> Any? {
        let string = { (key: String) in params[key] as? String ?? "" }
        let agent = { () -> AgentProfile? in self.model.agents.first { $0.id == string("id") } }
        switch method {
        case "settings.refresh":
            model.refreshAvailability()
            refreshMarkdownDefault()
            // Opening the page refreshes lazily: only stale sources (older than the TTL).
            model.quotaStore.request(reason: .pageOpened)
        case "settings.set":
            let value = params["value"]
            switch string("key") {
            case "appearance": model.appearance = value as? String ?? "system"
            case "language": model.appLanguage = value as? String ?? L10n.systemLanguage
            case "showMenuBar": UserDefaults.standard.set(value as? Bool ?? true, forKey: Self.menuBarKey)
            case "autoApprove": model.autoApprove = value as? Bool ?? false
            case "defaultAgent":
                if let id = value as? String, model.agents.contains(where: { $0.id == id }) { model.selectedAgentId = id }
            default: return ["ok": false]
            }
        case "settings.markdownDefault":
            Task { @MainActor in
                do {
                    try await MarkdownDefaultApp.register()
                } catch {
                    self.model.errorMessage = "无法设为默认打开方式：%@".localized(error.localizedDescription)
                }
                self.refreshMarkdownDefault()
            }
        case "agent.enable":
            if let agent = agent() { model.setAgentEnabled(agent, enabled: params["enabled"] as? Bool ?? true) }
        case "agent.remove":
            if let agent = agent() { model.removeAgent(agent) }
        case "agent.add":
            model.customTitle = string("title")
            model.customCommand = string("command")
            guard !model.customCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return ["ok": false] }
            model.addCustomAgent()
        case "agent.copyLaunch":
            if let agent = agent() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.launchLine, forType: .string)
            }
        case "quota.refresh":
            // Manual still respects a short per-source minimum interval and any 429 window.
            model.quotaStore.request(agent().map { [$0.id] }, reason: .manual)
        case "workspace.remove":
            model.removeWorkspace(string("path"))
        case "workspace.select":
            model.selectWorkspace(string("path"))
        case "mcp.add":
            let transport = McpServerConfig.Transport(rawValue: string("transport")) ?? .stdio
            let name = string("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return ["ok": false] }
            var command = ""
            var args: [String] = []
            if transport == .stdio {
                let parts = AgentCatalog.splitCommandLine(string("command").trimmingCharacters(in: .whitespacesAndNewlines))
                command = parts.first ?? ""
                args = Array(parts.dropFirst())
                guard !command.isEmpty else { return ["ok": false] }
            }
            model.mcpServers.append(McpServerConfig(
                name: name, transport: transport, command: command, arguments: args,
                url: string("url").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        case "mcp.enable":
            if let index = model.mcpServers.firstIndex(where: { $0.id.uuidString == string("id") }) {
                model.mcpServers[index].enabled = params["enabled"] as? Bool ?? true
            }
        case "mcp.remove":
            model.mcpServers.removeAll { $0.id.uuidString == string("id") }
        default:
            return nil
        }
        scheduleFlush()
        return ["ok": true]
    }

    func refreshMarkdownDefault() {
        markdownDefaultCache = MarkdownDefaultApp.isCurrent
        scheduleFlush()
    }
}
