import Foundation
import Observation
import Security

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
    /// Absolute amounts when the source reports them (tokens, requests, credits…).
    var used: Double?
    var limit: Double?

    var remainingPercent: Double {
        max(0.0, min(100.0, 100.0 - usedPercent))
    }

    var severity: HarnessQuotaSeverity {
        if remainingPercent <= 5.0 {
            return .critical
        } else if remainingPercent <= 20.0 {
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
            return "已重置".localized
        }
        let totalMinutes = Int(ceil(interval / 60.0))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "%1$lld 天 %2$lld 小时后重置".localized(days, hours)
        } else if hours > 0 {
            return "%1$lld 小时 %2$lld 分后重置".localized(hours, minutes)
        } else {
            return "%lld 分钟后重置".localized(max(1, minutes))
        }
    }
}

// MARK: - Quota Breakdown Item

struct HarnessQuotaBreakdownItem: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var title: String
    /// For a normal product this is that product's own used percent.
    /// When `pooled` is true it is this product's share of one shared pool
    /// (Grok Chat and Grok Build add up to the window), not a separate limit.
    var usedPercent: Double
    var pooled: Bool

    init(id: String, title: String, usedPercent: Double, pooled: Bool = false) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.pooled = pooled
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, usedPercent, pooled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        pooled = try container.decodeIfPresent(Bool.self, forKey: .pooled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(pooled, forKey: .pooled)
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
    var usageBreakdown: [HarnessQuotaBreakdownItem] = []
    var creditsRemaining: Double?
    var creditsUnit: String?
    var resetCreditsAvailable: Int?
    /// fetchedAt: when the source produced this reading (kept as `updatedAt` for on-disk compatibility).
    var updatedAt: Date
    var error: String?
    /// Which `QuotaSource` produced the reading and of what kind (official API / local CLI cache).
    var sourceId: String?
    var sourceKind: QuotaSourceKind?
    /// Last ACP-reported session usage for this harness. Supplementary only — never drives limits.
    var supplement: QuotaSessionSupplement?

    var fetchedAt: Date { updatedAt }

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
                if window.remainingPercent < current.remainingPercent {
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
            let pct = Int(round(urgent.remainingPercent))
            return "\(pct)%"
        }
        if let credits = creditsRemaining {
            return String(format: "%.0f", credits)
        }
        return "正常"
    }
}

// MARK: - Localhost Trust Session Delegate

/// Antigravity's language server presents a self-signed cert on loopback.
/// Evaluate first; only fall back to accepting that cert for 127.0.0.1 / localhost / ::1.
final class LocalhostTrustSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              Self.isLoopback(challenge.protectionSpace.host)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

// MARK: - Quota Fetcher

actor HarnessQuotaFetcher {
    static let localhostDelegate = LocalhostTrustSessionDelegate()
    static let localhostSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: localhostDelegate, delegateQueue: nil)
    }()

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

    /// Map Aureways agent id to normalized provider name for probing.
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

    /// Whether the (built-in) source config maps this harness to any quota source.
    static func supportsQuota(for agentId: String) -> Bool {
        !QuotaSourceConfig.builtIn.sourceIds(for: agentId).isEmpty
    }

    /// Maps a non-2xx response to a typed error (429 carries Retry-After).
    static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw QuotaFetchError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 429:
            throw QuotaFetchError.rateLimited(retryAfter: parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        case 401, 403: throw QuotaFetchError.unauthorized(http.statusCode)
        default: throw QuotaFetchError.http(http.statusCode)
        }
    }

    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    static func transportError(_ error: Error) -> QuotaFetchError {
        if let typed = error as? QuotaFetchError { return typed }
        return .network(error.localizedDescription)
    }
}
