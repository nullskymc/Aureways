import Foundation
import Observation

// MARK: - Quota Severity

enum HarnessQuotaSeverity: String, Sendable, Codable, Comparable {
    case healthy
    case warning
    case critical
    case unknown

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .healthy: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: HarnessQuotaSeverity, rhs: HarnessQuotaSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Quota Rate Window

struct HarnessQuotaWindow: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    var resetDescription: String?
    var windowMinutes: Int?

    var remainingPercent: Double {
        max(0.0, min(100.0, 100.0 - usedPercent))
    }

    var severity: HarnessQuotaSeverity {
        if usedPercent >= 95.0 {
            return .critical
        } else if usedPercent >= 80.0 {
            return .warning
        } else {
            return .healthy
        }
    }

    var countdownDescription: String? {
        if let resetDescription, !resetDescription.isEmpty {
            return resetDescription
        }
        guard let resetsAt else { return nil }
        let now = Date()
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 {
            return "已重置"
        }
        let totalMinutes = Int(ceil(interval / 60.0))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时后重置"
        } else if hours > 0 {
            return "\(hours) 小时 \(minutes) 分后重置"
        } else {
            return "\(max(1, minutes)) 分钟后重置"
        }
    }
}

// MARK: - Quota Snapshot

struct HarnessQuotaSnapshot: Identifiable, Sendable, Codable, Hashable {
    var id: String { harnessId }
    var harnessId: String
    var providerTitle: String
    var planType: String?
    var accountEmail: String?
    var primaryWindow: HarnessQuotaWindow?
    var secondaryWindow: HarnessQuotaWindow?
    var extraWindows: [HarnessQuotaWindow] = []
    var creditsRemaining: Double?
    var creditsUnit: String?
    var resetCreditsAvailable: Int?
    var updatedAt: Date
    var error: String?

    var overallSeverity: HarnessQuotaSeverity {
        var highest: HarnessQuotaSeverity = .healthy
        if let primary = primaryWindow, primary.severity > highest {
            highest = primary.severity
        }
        if let secondary = secondaryWindow, secondary.severity > highest {
            highest = secondary.severity
        }
        for extra in extraWindows where extra.severity > highest {
            highest = extra.severity
        }
        return highest
    }

    var mostUrgentWindow: HarnessQuotaWindow? {
        var candidate = primaryWindow
        for window in [secondaryWindow].compactMap({ $0 }) + extraWindows {
            if let current = candidate {
                if window.usedPercent > current.usedPercent {
                    candidate = window
                }
            } else {
                candidate = window
            }
        }
        return candidate
    }

    var shortSummary: String {
        if let urgent = mostUrgentWindow {
            let pct = Int(round(urgent.usedPercent))
            return "\(pct)%"
        }
        if let credits = creditsRemaining {
            return String(format: "%.0f", credits)
        }
        return "正常"
    }
}

// MARK: - Quota Fetcher

actor HarnessQuotaFetcher {
    static func parseDate(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let num = value as? NSNumber {
            return Date(timeIntervalSince1970: num.doubleValue)
        }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) {
                return date
            }
            if let timestamp = Double(str) {
                return Date(timeIntervalSince1970: timestamp)
            }
        }
        return nil
    }

    /// Map Aureways agent id to normalized provider name.
    static func mapAgentIdToProvider(_ agentId: String) -> String {
        switch agentId.lowercased() {
        case "codex": return "codex"
        case "claude", "claude-code": return "claude"
        case "antigravity", "gemini": return "antigravity"
        case "grok", "grok-build": return "grok"
        case "copilot", "github-copilot": return "copilot"
        case "cursor", "cursor-agent": return "cursor"
        case "opencode": return "opencode"
        default: return agentId.lowercased()
        }
    }

    func fetchQuota(for agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let provider = Self.mapAgentIdToProvider(agent.id)

        // All quota fetchers are completely native to Aureways (zero external dependencies)
        switch provider {
        case "codex":
            return await fetchCodexNative(agent: agent)
        case "grok":
            return await fetchGrokNative(agent: agent)
        case "antigravity":
            return await fetchAntigravityNative(agent: agent)
        default:
            return nil
        }
    }

    // MARK: - Native Grok Quota Probing

    private func fetchGrokNative(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let authPath = NSString(string: "~/.grok/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath),
              let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let firstEntry = authJSON.values.first as? [String: Any],
              let token = (firstEntry["key"] as? String) ?? (firstEntry["refresh_token"] as? String),
              !token.isEmpty
        else {
            return nil
        }

        let email = firstEntry["email"] as? String
        let authMode = firstEntry["auth_mode"] as? String

        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok/1.0 (Aureways)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = json["config"] as? [String: Any]
            else {
                return nil
            }

            let usedPercent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue ?? 0.0
            var resetsAt: Date? = nil
            if let currentPeriod = config["currentPeriod"] as? [String: Any] {
                resetsAt = Self.parseDate(currentPeriod["end"])
            } else if let endStr = config["billingPeriodEnd"] as? String {
                resetsAt = Self.parseDate(endStr)
            }

            let primaryWindow = HarnessQuotaWindow(
                id: "grok-weekly-window",
                title: "周限额 (Weekly)",
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                resetDescription: nil,
                windowMinutes: 10080
            )

            var extraWindows: [HarnessQuotaWindow] = []
            if let productUsage = config["productUsage"] as? [[String: Any]] {
                for item in productUsage {
                    if let product = item["product"] as? String,
                       let usage = (item["usagePercent"] as? NSNumber)?.doubleValue {
                        let friendlyTitle: String
                        switch product.lowercased() {
                        case "grokbuild": friendlyTitle = "Grok Build"
                        case "grokchat": friendlyTitle = "Grok Chat"
                        case "grokimagine": friendlyTitle = "Grok Imagine"
                        default: friendlyTitle = product
                        }
                        extraWindows.append(
                            HarnessQuotaWindow(
                                id: "grok-\(product.lowercased())",
                                title: friendlyTitle,
                                usedPercent: usage,
                                resetsAt: resetsAt,
                                resetDescription: nil,
                                windowMinutes: 10080
                            )
                        )
                    }
                }
            }

            let planTitle = authMode?.lowercased() == "oidc" ? "SuperGrok" : (authMode ?? "xAI Grok")

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: planTitle,
                accountEmail: email,
                primaryWindow: primaryWindow,
                secondaryWindow: nil,
                extraWindows: extraWindows,
                creditsRemaining: nil,
                creditsUnit: nil,
                resetCreditsAvailable: nil,
                updatedAt: Date()
            )
        } catch {
            return nil
        }
    }

    // MARK: - Native Antigravity Probing

    private func fetchAntigravityNative(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        // Read local token configuration
        let tokenPath = NSString(string: "~/.gemini/jetski-standalone-oauth-token").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: tokenPath),
              let tokenData = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
              let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let tokenDict = tokenJSON["token"] as? [String: Any],
              let accessToken = tokenDict["access_token"] as? String,
              !accessToken.isEmpty
        else {
            return nil
        }

        let authMethod = tokenJSON["auth_method"] as? String ?? "Google AI"

        // Query Cloud Code retrieveUserQuota endpoint
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aureways/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            var primary: HarnessQuotaWindow? = nil
            var secondary: HarnessQuotaWindow? = nil
            var extras: [HarnessQuotaWindow] = []

            if let buckets = json["buckets"] as? [[String: Any]] {
                for (idx, bucket) in buckets.enumerated() {
                    let title = bucket["modelName"] as? String ?? bucket["title"] as? String ?? "Model Limit"
                    let used = (bucket["usedPercent"] as? NSNumber)?.doubleValue ?? 0.0
                    let resetsAt = Self.parseDate(bucket["resetsAt"] ?? bucket["resetTime"])
                    let win = HarnessQuotaWindow(
                        id: "agy-window-\(idx)",
                        title: title,
                        usedPercent: used,
                        resetsAt: resetsAt,
                        resetDescription: nil,
                        windowMinutes: nil
                    )
                    if primary == nil {
                        primary = win
                    } else if secondary == nil {
                        secondary = win
                    } else {
                        extras.append(win)
                    }
                }
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: authMethod.capitalized,
                accountEmail: nil,
                primaryWindow: primary,
                secondaryWindow: secondary,
                extraWindows: extras,
                creditsRemaining: nil,
                creditsUnit: nil,
                resetCreditsAvailable: nil,
                updatedAt: Date()
            )
        } catch {
            return nil
        }
    }

    // MARK: - Native Codex Quota Probing

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

    private func fetchCodexNative(agent: AgentProfile) async -> HarnessQuotaSnapshot? {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath),
              let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = authJSON["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty
        else {
            return nil
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = tokens["account_id"] as? String, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("Aureways/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let email = json["email"] as? String
            let planType = json["plan_type"] as? String

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

            var credits: Double? = nil
            var currency: String? = nil
            if let creditsDict = json["credits"] as? [String: Any] {
                if let balNum = creditsDict["balance"] as? NSNumber {
                    credits = balNum.doubleValue
                } else if let balStr = creditsDict["balance"] as? String, let balVal = Double(balStr) {
                    credits = balVal
                }
                currency = "Credits"
            }

            var resetCreditsAvailable: Int? = nil
            if let resetCreditsDict = json["rate_limit_reset_credits"] as? [String: Any] {
                resetCreditsAvailable = resetCreditsDict["available_count"] as? Int
            }

            return HarnessQuotaSnapshot(
                harnessId: agent.id,
                providerTitle: agent.title,
                planType: planType?.capitalized,
                accountEmail: email,
                primaryWindow: primary,
                secondaryWindow: secondary,
                extraWindows: extras,
                creditsRemaining: credits,
                creditsUnit: currency,
                resetCreditsAvailable: resetCreditsAvailable,
                updatedAt: Date()
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Quota Observable Service

@Observable
@MainActor
final class HarnessQuotaService {
    private let fetcher = HarnessQuotaFetcher()
    private(set) var snapshots: [String: HarnessQuotaSnapshot] = [:]
    private(set) var isRefreshing: [String: Bool] = [:]
    private var lastFetchTimes: [String: Date] = [:]

    /// 180 seconds cache TTL
    private let cacheTTL: TimeInterval = 180.0

    func snapshot(for agentId: String) -> HarnessQuotaSnapshot? {
        snapshots[agentId]
    }

    func updateSnapshot(_ snapshot: HarnessQuotaSnapshot) {
        snapshots[snapshot.harnessId] = snapshot
    }

    func isBusy(for agentId: String) -> Bool {
        isRefreshing[agentId] ?? false
    }

    func refreshQuota(for agent: AgentProfile, force: Bool = false) {
        let agentId = agent.id
        if !force, let lastFetch = lastFetchTimes[agentId], Date().timeIntervalSince(lastFetch) < cacheTTL {
            return
        }
        guard !(isRefreshing[agentId] ?? false) else { return }

        isRefreshing[agentId] = true

        Task {
            let result = await self.fetcher.fetchQuota(for: agent)
            await MainActor.run {
                self.isRefreshing[agentId] = false
                self.lastFetchTimes[agentId] = Date()
                if let result {
                    self.snapshots[agentId] = result
                }
            }
        }
    }

    func refreshAll(agents: [AgentProfile], force: Bool = false) {
        for agent in agents {
            refreshQuota(for: agent, force: force)
        }
    }
}
