import Foundation

// MARK: - Native Codex Quota Probing

extension HarnessQuotaFetcher {
/// Codex reports `limit_window_seconds`; label the common ones the way the CLI does.
    static func codexWindowLabel(minutes: Int?, fallback: String) -> String {
        switch minutes {
        case 300: return "5h"
        case 10080: return "Weekly"
        case 1440: return "Daily"
        default: return fallback
        }
    }

    static func parseCodexWindow(_ dict: [String: Any]?, id: String, defaultTitle: String) -> QuotaWindow? {
        guard let dict, let used = (dict["used_percent"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let windowMin = (dict["limit_window_seconds"] as? NSNumber).map { $0.intValue / 60 }
        return QuotaWindow(
            id: id,
            label: codexWindowLabel(minutes: windowMin, fallback: defaultTitle),
            usedPercent: used,
            resetsAt: parseDate(dict["reset_at"]),
            windowMinutes: windowMin
        )
    }

    /// `wham/usage` body → unified quota. Pure, so fixtures can test it.
    static func parseCodexUsage(_ data: Data, agent: AgentProfile, auth: (email: String?, planType: String?), now: Date = Date()) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        let email = (json["email"] as? String) ?? auth.email
        let planType = (json["plan_type"] as? String) ?? auth.planType
        var windows: [QuotaWindow] = []
        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let w = parseCodexWindow(rateLimit["primary_window"] as? [String: Any], id: "codex-primary", defaultTitle: "5h") { windows.append(w) }
            if let w = parseCodexWindow(rateLimit["secondary_window"] as? [String: Any], id: "codex-secondary", defaultTitle: "Weekly") { windows.append(w) }
        }
        if let codeReview = json["code_review_rate_limit"] as? [String: Any],
           var win = parseCodexWindow(codeReview["primary_window"] as? [String: Any], id: "codex-code-review", defaultTitle: "Code review") {
            win.label = "Code review"
            win.kind = .other
            windows.append(win)
        }
        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for (index, item) in additional.enumerated() {
                let title = (item["limit_name"] as? String) ?? "Extra"
                if var win = parseCodexWindow(item["rate_limit"] as? [String: Any], id: "codex-extra-\(index)", defaultTitle: title) {
                    win.label = title
                    win.kind = .model
                    windows.append(win)
                }
            }
        }
        if let creditsDict = json["credits"] as? [String: Any] {
            var balance = (creditsDict["balance"] as? NSNumber)?.doubleValue
            if balance == nil, let text = creditsDict["balance"] as? String { balance = Double(text) }
            if let balance {
                windows.append(QuotaWindow(id: "codex-credits", label: "Credits", kind: .credits, balance: balance, unit: creditsDict["unit"] as? String))
            }
        }
        var resetsAvail: Int? = nil
        if let resetsDict = json["resets"] as? [String: Any] {
            resetsAvail = (resetsDict["available"] as? NSNumber)?.intValue
        }
        if resetsAvail == nil, let resetCreditsDict = json["rate_limit_reset_credits"] as? [String: Any] {
            resetsAvail = (resetCreditsDict["available_count"] as? NSNumber)?.intValue
        }
        guard !windows.isEmpty else { throw QuotaFetchError.invalidResponse }
        return ProviderQuota(
            harnessId: agent.id, providerTitle: agent.title, plan: planType?.capitalized, account: email,
            windows: windows, lastUpdated: now, resetCreditsAvailable: resetsAvail
        )
    }

    static func extractCodexAuth(_ authJSON: [String: Any]) -> (token: String, accountId: String?, email: String?, planType: String?)? {
        let tokens = authJSON["tokens"] as? [String: Any]
        let token = (tokens?["access_token"] as? String)
            ?? (authJSON["access_token"] as? String)
            ?? (authJSON["token"] as? String)
        guard let token, !token.isEmpty else { return nil }
        let accountId = (tokens?["account_id"] as? String) ?? (authJSON["account_id"] as? String)
        let email = (tokens?["email"] as? String) ?? (authJSON["email"] as? String)
        let planType = (tokens?["plan_type"] as? String) ?? (authJSON["plan_type"] as? String)
        return (token, accountId, email, planType)
    }

    func fetchCodex(agent: AgentProfile) async throws -> ProviderQuota {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath),
              let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let auth = Self.extractCodexAuth(authJSON)
        else {
            throw QuotaFetchError.notConfigured
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw QuotaFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex/1.0 (Aureways)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkHTTP(response)
            return try Self.parseCodexUsage(data, agent: agent, auth: (auth.email, auth.planType))
        } catch {
            throw Self.transportError(error)
        }
    }
}