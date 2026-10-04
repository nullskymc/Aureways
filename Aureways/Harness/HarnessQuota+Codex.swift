import Foundation

// MARK: - Native Codex Quota Probing

extension HarnessQuotaFetcher {
private func parseCodexWindow(_ dict: [String: Any]?, id: String = UUID().uuidString, defaultTitle: String) -> HarnessQuotaWindow? {
        guard let dict, let used = (dict["used_percent"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let resetsAt = Self.parseDate(dict["reset_at"])
        let windowSec = dict["limit_window_seconds"] as? Int
        let windowMin = windowSec.map { $0 / 60 }

        return HarnessQuotaWindow(
            id: id,
            title: defaultTitle,
            usedPercent: used,
            resetsAt: resetsAt,
            resetDescription: nil,
            windowMinutes: windowMin
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

    func fetchCodex(agent: AgentProfile) async throws -> HarnessQuotaSnapshot {
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QuotaFetchError.invalidResponse
            }

            let email = (json["email"] as? String) ?? auth.email
            let planType = (json["plan_type"] as? String) ?? auth.planType

            var primary: HarnessQuotaWindow? = nil
            var secondary: HarnessQuotaWindow? = nil
            var extras: [HarnessQuotaWindow] = []

            if let rateLimit = json["rate_limit"] as? [String: Any] {
                primary = parseCodexWindow(rateLimit["primary_window"] as? [String: Any], id: "codex-primary", defaultTitle: "主限额 (Session)")
                secondary = parseCodexWindow(rateLimit["secondary_window"] as? [String: Any], id: "codex-secondary", defaultTitle: "周限额 (Weekly)")
            }

            if let codeReview = json["code_review_rate_limit"] as? [String: Any],
               let win = parseCodexWindow(codeReview["primary_window"] as? [String: Any], id: "codex-code-review", defaultTitle: "代码审查限额") {
                extras.append(win)
            }

            if let additional = json["additional_rate_limits"] as? [[String: Any]] {
                for item in additional {
                    let title = (item["limit_name"] as? String) ?? "额外限额"
                    if let win = parseCodexWindow(item["rate_limit"] as? [String: Any], id: UUID().uuidString, defaultTitle: title) {
                        extras.append(win)
                    }
                }
            }

            var creditsVal: Double? = nil
            var creditsUnit: String? = nil
            if let creditsDict = json["credits"] as? [String: Any] {
                if let balance = (creditsDict["balance"] as? NSNumber)?.doubleValue {
                    creditsVal = balance
                } else if let balance = creditsDict["balance"] as? String, let parsed = Double(balance) {
                    creditsVal = parsed
                }
                if creditsVal != nil {
                    creditsUnit = creditsDict["unit"] as? String ?? "Credits"
                }
            }

            var resetsAvail: Int? = nil
            if let resetsDict = json["resets"] as? [String: Any] {
                resetsAvail = (resetsDict["available"] as? NSNumber)?.intValue
            }
            if resetsAvail == nil, let resetCreditsDict = json["rate_limit_reset_credits"] as? [String: Any] {
                resetsAvail = (resetCreditsDict["available_count"] as? NSNumber)?.intValue
                    ?? resetCreditsDict["available_count"] as? Int
            }

            guard primary != nil || secondary != nil || !extras.isEmpty || creditsVal != nil else {
                throw QuotaFetchError.invalidResponse
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: planType?.capitalized,
                accountEmail: email,
                primaryWindow: primary,
                secondaryWindow: secondary,
                extraWindows: extras,
                usageBreakdown: [],
                creditsRemaining: creditsVal,
                creditsUnit: creditsUnit,
                resetCreditsAvailable: resetsAvail,
                updatedAt: Date()
            )
        } catch {
            throw Self.transportError(error)
        }
    }
}