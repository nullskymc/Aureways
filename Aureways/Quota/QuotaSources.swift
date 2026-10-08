import Foundation

// MARK: - Errors and supplements (the model itself is in ProviderQuota.swift)

/// Typed fetch failure. `kind` is what the UI shows (web side localizes it).
enum QuotaFetchError: Error, Sendable, Equatable {
    /// No login / credentials for this source on this machine.
    case notConfigured
    case unauthorized(Int)
    /// HTTP 429. `retryAfter` from the header (seconds), when present.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case invalidResponse
    case network(String)
    /// The source exists but had nothing to report (e.g. no local data yet).
    case unavailable

    var kind: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rateLimited"
        case .http(let code): return "http \(code)"
        case .invalidResponse: return "invalidResponse"
        case .network: return "network"
        case .unavailable: return "unavailable"
        }
    }

    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}

/// Latest ACP `usage_update` seen for a harness (context tokens / cost of one session).
/// Supplementary: shown next to the account quota, never used to compute limits.
struct QuotaSessionSupplement: Sendable, Codable, Hashable {
    var usedTokens: Int
    var contextTokens: Int
    var costAmount: Double?
    var costCurrency: String?
    var reportedAt: Date
}

// MARK: - Source protocol

protocol QuotaSource: Sendable {
    /// Stable id used by the config map, caches and backoff state (e.g. "codex.usage-api").
    var id: String { get }
    var kind: QuotaSourceKind { get }
    func fetch(for agent: AgentProfile) async throws -> ProviderQuota
}

/// Shared actor for the network fetchers (Antigravity probing keeps per-process state).
private let sharedFetcher = HarnessQuotaFetcher()

struct CodexUsageAPISource: QuotaSource {
    let id = "codex.usage-api"
    let kind = QuotaSourceKind.officialAPI
    func fetch(for agent: AgentProfile) async throws -> ProviderQuota {
        try await sharedFetcher.fetchCodex(agent: agent)
    }
}

struct GrokBillingSource: QuotaSource {
    let id = "grok.billing"
    let kind = QuotaSourceKind.officialAPI
    func fetch(for agent: AgentProfile) async throws -> ProviderQuota {
        try await sharedFetcher.fetchGrok(agent: agent)
    }
}

struct AntigravityCloudCodeSource: QuotaSource {
    let id = "antigravity.cloudcode"
    let kind = QuotaSourceKind.officialAPI
    func fetch(for agent: AgentProfile) async throws -> ProviderQuota {
        try await sharedFetcher.fetchAntigravity(agent: agent)
    }
}

/// Claude Code subscription usage via the OAuth usage endpoint, using the token the
/// CLI stores in `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`). On macOS the
/// CLI usually keeps it in the Keychain instead; we deliberately don't read the Keychain
/// (it would prompt), so this reports `notConfigured` there.
struct ClaudeOAuthUsageSource: QuotaSource {
    let id = "claude.oauth-usage"
    let kind = QuotaSourceKind.officialAPI

    static func credentialsPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let base = environment["CLAUDE_CONFIG_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? NSString(string: "~/.claude").expandingTildeInPath
        return (base as NSString).appendingPathComponent(".credentials.json")
    }

    static func extractToken(_ json: [String: Any]) -> (token: String, plan: String?)? {
        let oauth = json["claudeAiOauth"] as? [String: Any] ?? json
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }

    static func parseUsage(_ data: Data, agent: AgentProfile, plan: String?, now: Date = Date()) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        func window(_ key: String, id: String, label: String, minutes: Int) -> QuotaWindow? {
            guard let dict = json[key] as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(
                id: id, label: label, usedPercent: utilization,
                resetsAt: HarnessQuotaFetcher.parseDate(dict["resets_at"]), windowMinutes: minutes
            )
        }
        let windows = [
            window("five_hour", id: "claude-5h", label: "5h", minutes: 300),
            window("seven_day", id: "claude-7d", label: "Weekly", minutes: 10080),
            window("seven_day_opus", id: "claude-7d-opus", label: "Weekly Opus", minutes: 10080),
            window("seven_day_sonnet", id: "claude-7d-sonnet", label: "Weekly Sonnet", minutes: 10080),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw QuotaFetchError.invalidResponse }
        return ProviderQuota(
            harnessId: agent.id, providerTitle: agent.title, plan: plan?.capitalized,
            windows: windows, lastUpdated: now
        )
    }

    func fetch(for agent: AgentProfile) async throws -> ProviderQuota {
        let path = Self.credentialsPath()
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creds = Self.extractToken(json),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage")
        else { throw QuotaFetchError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aureways", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            try HarnessQuotaFetcher.checkHTTP(response)
            return try Self.parseUsage(body, agent: agent, plan: creds.plan)
        } catch {
            throw HarnessQuotaFetcher.transportError(error)
        }
    }
}

/// Codex CLI writes `token_count` events with `rate_limits` into its rollout logs
/// (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`). Reading the newest one costs no
/// network at all, so it's the fallback when the usage API isn't reachable / logged in.
struct CodexSessionLogSource: QuotaSource {
    let id = "codex.session-log"
    let kind = QuotaSourceKind.localEstimate
    var home: String?
    /// Only look this many days back.
    var lookbackDays = 7

    static func codexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["CODEX_HOME"].map { NSString(string: $0).expandingTildeInPath }
            ?? NSString(string: "~/.codex").expandingTildeInPath
    }

    /// Parses one rollout line; nil unless it carries non-empty `rate_limits`.
    /// Parses one rollout line; nil unless it carries non-empty `rate_limits`. The numbers
    /// are what the server told the CLI at that moment, so they're flagged as an estimate.
    static func parseRolloutLine(_ line: Data, agent: AgentProfile) -> ProviderQuota? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let payload = json["payload"] as? [String: Any] ?? json
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let at = HarnessQuotaFetcher.parseDate(json["timestamp"]) ?? Date()
        func window(_ key: String, id: String, fallback: String) -> QuotaWindow? {
            guard let dict = limits[key] as? [String: Any],
                  let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            var resets = HarnessQuotaFetcher.parseDate(dict["resets_at"])
            if resets == nil, let seconds = (dict["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resets = at.addingTimeInterval(seconds)
            }
            let minutes = (dict["window_minutes"] as? NSNumber)?.intValue
            return QuotaWindow(
                id: id, label: HarnessQuotaFetcher.codexWindowLabel(minutes: minutes, fallback: fallback),
                usedPercent: used, resetsAt: resets, windowMinutes: minutes, source: .localEstimate
            )
        }
        let windows = [
            window("primary", id: "codex-primary", fallback: "5h"),
            window("secondary", id: "codex-secondary", fallback: "Weekly"),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return ProviderQuota(
            harnessId: agent.id, providerTitle: agent.title,
            plan: (limits["plan_type"] as? String)?.capitalized,
            windows: windows, lastUpdated: at
        )
    }

    /// Newest-first rollout files from the last `lookbackDays` day directories.
    func recentRolloutFiles(now: Date = Date()) -> [URL] {
        let root = URL(fileURLWithPath: home ?? Self.codexHome()).appendingPathComponent("sessions")
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var files: [(URL, Date)] = []
        for offset in 0..<max(1, lookbackDays) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                files.append((url, mtime))
            }
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func latestSnapshot(inFile url: URL, agent: AgentProfile, tailBytes: Int = 512 * 1024) -> ProviderQuota? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let snapshot = parseRolloutLine(Data(line), agent: agent) { return snapshot }
        }
        return nil
    }

    func fetch(for agent: AgentProfile) async throws -> ProviderQuota {
        let files = recentRolloutFiles()
        guard !files.isEmpty else { throw QuotaFetchError.notConfigured }
        for file in files.prefix(10) {
            if let snapshot = Self.latestSnapshot(inFile: file, agent: agent) { return snapshot }
        }
        throw QuotaFetchError.unavailable
    }
}

// MARK: - Harness → source mapping (config)

/// Which sources (in priority order) serve each harness. The built-in table is just the
/// default; `defaults write <bundle> quotaSourceMap -dict codex '(codex.session-log)'`
/// (or a JSON string) overrides per harness, and an empty list disables quota for it.
struct QuotaSourceConfig: Sendable, Equatable {
    static let defaultsKey = "quotaSourceMap"

    static let builtIn = QuotaSourceConfig(map: [
        "codex": ["codex.usage-api", "codex.session-log"],
        "claude": ["claude.oauth-usage"],
        "claude-code": ["claude.oauth-usage"],
        "grok": ["grok.billing"],
        "grok-build": ["grok.billing"],
        "antigravity": ["antigravity.cloudcode"],
        "gemini": ["antigravity.cloudcode"],
    ])

    var map: [String: [String]]

    func sourceIds(for harnessId: String) -> [String] {
        map[harnessId] ?? map[harnessId.lowercased()] ?? []
    }

    func merging(_ overrides: [String: [String]]) -> QuotaSourceConfig {
        QuotaSourceConfig(map: map.merging(overrides) { _, new in new })
    }

    static func parseOverrides(_ raw: Any?) -> [String: [String]] {
        var object = raw
        if let string = raw as? String, let data = string.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data)
        }
        guard let dict = object as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (key, value) in dict {
            if let list = value as? [String] { out[key] = list }
            else if let single = value as? String { out[key] = single.isEmpty ? [] : [single] }
        }
        return out
    }

    static func load(defaults: UserDefaults = .standard) -> QuotaSourceConfig {
        builtIn.merging(parseOverrides(defaults.object(forKey: defaultsKey)))
    }
}

enum QuotaSourceRegistry {
    static let builtIn: [String: any QuotaSource] = {
        let sources: [any QuotaSource] = [
            CodexUsageAPISource(), CodexSessionLogSource(), ClaudeOAuthUsageSource(),
            GrokBillingSource(), AntigravityCloudCodeSource(),
        ]
        return Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }()
}
