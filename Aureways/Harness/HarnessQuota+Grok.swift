import Foundation

// MARK: - Native Grok Quota Probing

extension HarnessQuotaFetcher {
func fetchGrok(agent: AgentProfile) async throws -> HarnessQuotaSnapshot {
        let authPath = NSString(string: "~/.grok/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath),
              let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let firstEntry = authJSON.values.first as? [String: Any],
              let token = (firstEntry["key"] as? String) ?? (firstEntry["refresh_token"] as? String) ?? (firstEntry["access_token"] as? String),
              !token.isEmpty
        else {
            throw QuotaFetchError.notConfigured
        }

        let email = firstEntry["email"] as? String
        let authMode = firstEntry["auth_mode"] as? String

        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            throw QuotaFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok/1.0 (Aureways)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkHTTP(response)
            let planTitle = authMode?.lowercased() == "oidc" ? "SuperGrok" : (authMode ?? "xAI Grok")
            return try Self.parseGrokBilling(data, agent: agent, email: email, planTitle: planTitle)
        } catch {
            throw Self.transportError(error)
        }
    }

    /// Grok Chat and Grok Build share one credit pool when `isUnifiedBillingUser`
    /// is set, or when the product percents add up to `creditUsagePercent`.
    /// Those percents are shares of that pool. They are not each a 100% limit.
    static func parseGrokBilling(
        _ data: Data,
        agent: AgentProfile,
        email: String?,
        planTitle: String,
        now: Date = Date()
    ) throws -> HarnessQuotaSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["config"] as? [String: Any]
        else {
            throw QuotaFetchError.invalidResponse
        }

        var creditUsed = (config["creditUsagePercent"] as? NSNumber)?.doubleValue
        if creditUsed == nil {
            if let onDemandUsed = (config["onDemandUsed"] as? [String: Any])?["val"] as? NSNumber,
               let onDemandCap = (config["onDemandCap"] as? [String: Any])?["val"] as? NSNumber,
               onDemandCap.doubleValue > 0 {
                creditUsed = (onDemandUsed.doubleValue / onDemandCap.doubleValue) * 100.0
            }
        }

        var resetsAt: Date?
        if let currentPeriod = config["currentPeriod"] as? [String: Any] {
            resetsAt = parseDate(currentPeriod["end"])
        } else if let endStr = config["billingPeriodEnd"] as? String {
            resetsAt = parseDate(endStr)
        }

        var shares: [(id: String, title: String, percent: Double)] = []
        if let productUsage = config["productUsage"] as? [[String: Any]] {
            for item in productUsage {
                guard let product = item["product"] as? String,
                      let usage = (item["usagePercent"] as? NSNumber)?.doubleValue else { continue }
                let title: String
                switch product.lowercased() {
                case "grokbuild": title = "Grok Build"
                case "grokchat": title = "Grok Chat"
                case "grokimagine": title = "Grok Imagine"
                default: title = product
                }
                shares.append((id: "grok-\(product.lowercased())", title: title, percent: usage))
            }
        }

        let shareSum = shares.reduce(0.0) { $0 + $1.percent }
        let unifiedFlag = config["isUnifiedBillingUser"] as? Bool ?? false
        let sumsToCredit = creditUsed.map { abs(shareSum - $0) <= 1.0 && !shares.isEmpty } ?? false
        let pooled = unifiedFlag || sumsToCredit
        let totalUsed = creditUsed ?? (pooled ? shareSum : 0.0)

        guard creditUsed != nil || !shares.isEmpty else {
            throw QuotaFetchError.invalidResponse
        }

        let primaryWindow = HarnessQuotaWindow(
            id: "grok-weekly-window",
            title: "共享周限额 (Weekly)",
            usedPercent: totalUsed,
            resetsAt: resetsAt,
            resetDescription: nil,
            windowMinutes: 10080
        )
        let breakdown = shares.map {
            HarnessQuotaBreakdownItem(id: $0.id, title: $0.title, usedPercent: $0.percent, pooled: pooled)
        }

        return HarnessQuotaSnapshot(
            harnessId: agent.id,
            providerTitle: agent.title,
            planType: planTitle,
            accountEmail: email,
            primaryWindow: primaryWindow,
            secondaryWindow: nil,
            extraWindows: [],
            usageBreakdown: breakdown,
            creditsRemaining: nil,
            creditsUnit: nil,
            resetCreditsAvailable: nil,
            updatedAt: now
        )
    }
}
