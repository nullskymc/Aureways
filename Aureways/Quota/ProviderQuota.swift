import Foundation

// MARK: - Unified quota model
//
// Every provider adapter (Grok, Codex, Claude, Antigravity, …) produces one
// `ProviderQuota`. The store, the menu bar icon, notifications and the web UI
// read only this shape, so adding a harness means writing one adapter.

/// Where a number came from. Anything not read from the provider's own account
/// endpoint is an estimate, and the UI prefixes it with 约 / "~".
enum QuotaSourceKind: String, Sendable, Codable {
    /// The provider's own account/usage endpoint, authenticated with the CLI's login.
    case officialAPI
    /// Derived from something the CLI wrote to disk (session logs, caches). No network.
    case localEstimate
    /// Entered by the user.
    case manual

    var isEstimate: Bool { self != .officialAPI }

    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "localEstimate", "localCache": self = .localEstimate
        case "manual": self = .manual
        default: self = .officialAPI
        }
    }
}

/// Colour band for a remaining percentage: >50 green, 20–50 orange, <20 red.
enum QuotaLevel: String, Sendable, Codable, Comparable {
    case unknown, ample, moderate, low

    init(remainingPercent: Double?) {
        guard let remaining = remainingPercent else { self = .unknown; return }
        if remaining > 50 { self = .ample } else if remaining >= 20 { self = .moderate } else { self = .low }
    }

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .ample: return 1
        case .moderate: return 2
        case .low: return 3
        }
    }

    static func < (lhs: QuotaLevel, rhs: QuotaLevel) -> Bool { lhs.rank < rhs.rank }
}

/// One product's part of a shared pool (Grok Chat + Grok Build add up to the window).
struct QuotaShare: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var title: String
    var usedPercent: Double
}

/// One limit: a rolling window (5h / weekly / monthly), a per-model bucket, or a credit balance.
struct QuotaWindow: Identifiable, Sendable, Codable, Hashable {
    enum Kind: String, Sendable, Codable {
        case session, daily, weekly, monthly, credits, model, other
    }

    var id: String
    var label: String
    var kind: Kind
    /// Percent of the limit used, when the source reports a percentage.
    var usedPercent: Double?
    /// Absolute amounts, when the source reports them (requests, tokens, credits…).
    var used: Double?
    var limit: Double?
    /// A balance with no limit (e.g. prepaid credits). Has no percentage.
    var balance: Double?
    var unit: String?
    var resetsAt: Date?
    var resetDescription: String?
    var windowMinutes: Int?
    var source: QuotaSourceKind
    /// Pooled products, when several products draw on this one limit.
    var shares: [QuotaShare]

    init(
        id: String, label: String, kind: Kind? = nil,
        usedPercent: Double? = nil, used: Double? = nil, limit: Double? = nil,
        balance: Double? = nil, unit: String? = nil,
        resetsAt: Date? = nil, resetDescription: String? = nil, windowMinutes: Int? = nil,
        source: QuotaSourceKind = .officialAPI, shares: [QuotaShare] = []
    ) {
        self.id = id
        self.label = label
        self.kind = kind ?? Self.kind(forMinutes: windowMinutes, hasBalance: balance != nil)
        self.usedPercent = usedPercent
        self.used = used
        self.limit = limit
        self.balance = balance
        self.unit = unit
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.windowMinutes = windowMinutes
        self.source = source
        self.shares = shares
    }

    static func kind(forMinutes minutes: Int?, hasBalance: Bool = false) -> Kind {
        if hasBalance { return .credits }
        guard let minutes else { return .other }
        switch minutes {
        case ..<720: return .session
        case ..<2880: return .daily
        case ..<14400: return .weekly
        default: return .monthly
        }
    }

    /// Used percent from the reported percentage, else from used / limit.
    var resolvedUsedPercent: Double? {
        if let usedPercent { return usedPercent }
        if let used, let limit, limit > 0 { return used / limit * 100 }
        return nil
    }

    /// What the UI shows everywhere: how much is LEFT (0…100), nil for a bare balance.
    var remainingPercent: Double? {
        resolvedUsedPercent.map { max(0, min(100, 100 - $0)) }
    }

    var level: QuotaLevel { QuotaLevel(remainingPercent: remainingPercent) }
    var isEstimated: Bool { source.isEstimate }

    /// The window rolled over since this reading was taken.
    func hasReset(now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

/// A provider's quota as everything else sees it.
struct ProviderQuota: Identifiable, Sendable, Codable, Hashable {
    enum Status: String, Sendable, Codable {
        /// Fresh reading.
        case ok
        /// No CLI login on this Mac (or it expired): `statusDetail` says which.
        case notSignedIn
        /// This harness has no quota source.
        case unsupported
        /// Nothing to show; `statusDetail` carries the error kind.
        case error
        /// Showing an older reading: the last fetch failed, it is old, or a window reset since.
        case stale
    }

    var id: String { harnessId }
    var harnessId: String
    var providerTitle: String
    var plan: String?
    var account: String?
    var windows: [QuotaWindow]
    var status: Status
    /// Error kind for `.error` / `.notSignedIn` / `.stale` (rateLimited, network, notConfigured, …).
    var statusDetail: String?
    /// When the source produced this reading. nil = never fetched.
    var lastUpdated: Date?
    var sourceId: String?
    var sourceKind: QuotaSourceKind?
    var resetCreditsAvailable: Int?
    /// Last ACP-reported session usage. Supplementary only; never drives limits.
    var supplement: QuotaSessionSupplement?

    init(
        harnessId: String, providerTitle: String, plan: String? = nil, account: String? = nil,
        windows: [QuotaWindow] = [], status: Status = .ok, statusDetail: String? = nil,
        lastUpdated: Date? = nil, sourceId: String? = nil, sourceKind: QuotaSourceKind? = nil,
        resetCreditsAvailable: Int? = nil, supplement: QuotaSessionSupplement? = nil
    ) {
        self.harnessId = harnessId
        self.providerTitle = providerTitle
        self.plan = plan
        self.account = account
        self.windows = windows
        self.status = status
        self.statusDetail = statusDetail
        self.lastUpdated = lastUpdated
        self.sourceId = sourceId
        self.sourceKind = sourceKind
        self.resetCreditsAvailable = resetCreditsAvailable
        self.supplement = supplement
    }

    /// A reading older than this is shown as stale.
    static let staleAfter: TimeInterval = 24 * 3600

    static func placeholder(harnessId: String, title: String, status: Status, detail: String? = nil) -> ProviderQuota {
        ProviderQuota(harnessId: harnessId, providerTitle: title, status: status, statusDetail: detail)
    }

    var hasData: Bool { !windows.isEmpty }

    /// Windows with a percentage (everything except bare balances).
    var rateWindows: [QuotaWindow] { windows.filter { $0.remainingPercent != nil } }

    /// The limit that runs out first. The panel shows only this one per row.
    var tightestWindow: QuotaWindow? {
        rateWindows.min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
    }

    var remainingPercent: Double? { tightestWindow?.remainingPercent }
    var level: QuotaLevel { QuotaLevel(remainingPercent: remainingPercent) }
    var isEstimated: Bool { tightestWindow?.isEstimated ?? windows.contains { $0.isEstimated } }

    /// `status`, upgraded to `.stale` when an ok reading aged out or a window reset since.
    func effectiveStatus(now: Date) -> Status {
        guard status == .ok, hasData else { return status }
        if let lastUpdated, now.timeIntervalSince(lastUpdated) > Self.staleAfter { return .stale }
        if tightestWindow?.hasReset(now: now) == true { return .stale }
        return .ok
    }

    /// Short text for the settings badge ("62%").
    var shortSummary: String? {
        if let remaining = remainingPercent { return "\(Int(remaining.rounded()))%" }
        if let balance = windows.first(where: { $0.balance != nil })?.balance {
            return String(format: "%.0f", balance)
        }
        return nil
    }
}
