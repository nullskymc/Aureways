import Foundation

// MARK: - Request control policy

/// All request-rate knobs in one place. Defaults are deliberately conservative:
/// the user asked for no frequent quota requests.
struct QuotaRequestPolicy: Sendable, Equatable {
    /// Automatic refreshes (menu bar panel / usage page opened, turn end) skip a source
    /// fetched less than this long ago.
    var minInterval: TimeInterval = 300
    /// Manual refresh button: still at most one request per source per this interval.
    var manualMinInterval: TimeInterval = 30
    /// Turn-end / session events are coalesced: fire once this long after the last event.
    var eventDebounce: TimeInterval = 15
    /// Failure backoff: base * 2^(n-1), capped. 429 uses max(backoff, Retry-After).
    var backoffBase: TimeInterval = 60
    var backoffMax: TimeInterval = 1800
    /// Missing login: no point retrying soon (manual refresh still can, after manualMinInterval).
    var notConfiguredBackoff: TimeInterval = 1800
    /// Retry-After values beyond this are clamped.
    var retryAfterMax: TimeInterval = 6 * 3600

    static let standard = QuotaRequestPolicy()
}

/// The only things that may trigger a quota request. There is no launch fetch and no
/// background polling: between these, everything reads the cache.
enum QuotaRefreshReason: String, Sendable {
    /// The menu bar panel or the Usage settings page became visible (stale sources only).
    case pageOpened, menuBarOpened
    /// A turn of this harness finished (debounced, then TTL-gated).
    case sessionEvent
    /// The refresh button.
    case manual

    var isManual: Bool { self == .manual }
}

/// Per-source request bookkeeping, persisted with the cache so throttling survives relaunch.
struct QuotaSourceState: Sendable, Codable, Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var consecutiveFailures = 0
    var retryNotBefore: Date?
    var rateLimited = false
    var lastError: String?

    /// Pure throttle decision — the heart of request control (unit tested).
    func allowsFetch(reason: QuotaRefreshReason, now: Date, policy: QuotaRequestPolicy) -> Bool {
        let sinceLast = lastAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        if let notBefore = retryNotBefore, now < notBefore {
            // In backoff. A manual click may retry a plain failure (e.g. the user just
            // logged in), never a server-imposed 429 window.
            return reason.isManual && !rateLimited && sinceLast >= policy.manualMinInterval
        }
        return sinceLast >= (reason.isManual ? policy.manualMinInterval : policy.minInterval)
    }

    mutating func recordSuccess(at now: Date) {
        lastAttempt = now
        lastSuccess = now
        consecutiveFailures = 0
        retryNotBefore = nil
        rateLimited = false
        lastError = nil
    }

    mutating func recordFailure(_ error: QuotaFetchError, at now: Date, policy: QuotaRequestPolicy) {
        lastAttempt = now
        consecutiveFailures += 1
        lastError = error.kind
        rateLimited = error.isRateLimit
        var delay = min(policy.backoffMax, policy.backoffBase * pow(2, Double(consecutiveFailures - 1)))
        switch error {
        case .rateLimited(let retryAfter):
            delay = max(delay, min(retryAfter ?? 0, policy.retryAfterMax))
        case .notConfigured:
            delay = max(delay, policy.notConfiguredBackoff)
        default: break
        }
        retryNotBefore = now.addingTimeInterval(delay)
    }
}

// MARK: - Store

/// The single owner of account quota. Independent from ACP: it never looks at sessions or
/// runtimes, works with nothing connected, and every refresh goes through the per-source
/// throttle (TTL, single-flight, debounce, backoff). Requests happen only when the panel
/// opens or right after a turn; the UI only reads `quotas` / `providers(for:)`.
@Observable
@MainActor
final class QuotaStore {
    /// Display quota keyed by harness id.
    private(set) var quotas: [String: ProviderQuota] = [:]
    private(set) var isRefreshing: [String: Bool] = [:]

    @ObservationIgnored private(set) var sourceStates: [String: QuotaSourceState] = [:]
    /// Last good reading per source id (independent of which harness asked).
    @ObservationIgnored private var sourceCache: [String: ProviderQuota] = [:]
    @ObservationIgnored private var supplements: [String: QuotaSessionSupplement] = [:]
    @ObservationIgnored private var sourceInFlight: [String: Task<Result<ProviderQuota, QuotaFetchError>, Never>] = [:]
    @ObservationIgnored private var harnessInFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingEventHarnesses: Set<String> = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    @ObservationIgnored let policy: QuotaRequestPolicy
    @ObservationIgnored var config: QuotaSourceConfig
    @ObservationIgnored private let sources: [String: any QuotaSource]
    @ObservationIgnored private let cacheURL: URL?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Agents eligible for quota (set by AppModel). Pure data — no session state.
    @ObservationIgnored var agentsProvider: @MainActor () -> [AgentProfile] = { [] }
    /// Called after a refresh changed readings (usage notifications).
    @ObservationIgnored var onQuotasUpdated: (@MainActor ([ProviderQuota]) -> Void)?
    /// Count of real source fetches (diagnostics / tests).
    @ObservationIgnored private(set) var fetchCount = 0

    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aureways", isDirectory: true)
            .appendingPathComponent("quota-cache.json")
    }

    init(
        policy: QuotaRequestPolicy = .standard,
        config: QuotaSourceConfig = .load(),
        sources: [String: any QuotaSource] = QuotaSourceRegistry.builtIn,
        cacheURL: URL? = QuotaStore.defaultCacheURL,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    ) {
        self.policy = policy
        self.config = config
        self.sources = sources
        self.cacheURL = cacheURL
        self.now = now
        self.sleep = sleep
        loadCache()
    }

    // MARK: Reading

    func quota(for harnessId: String) -> ProviderQuota? { quotas[harnessId] }

    func supportsQuota(_ harnessId: String) -> Bool { !chain(for: harnessId).isEmpty }

    /// One entry per agent, in order: the reading, or a placeholder saying why there is none
    /// (`unsupported`, or `ok` with no windows = not fetched yet).
    func providers(for agents: [AgentProfile]) -> [ProviderQuota] {
        agents.map { agent in
            guard supportsQuota(agent.id) else {
                return .placeholder(harnessId: agent.id, title: agent.title, status: .unsupported)
            }
            var quota = quotas[agent.id] ?? .placeholder(harnessId: agent.id, title: agent.title, status: .ok)
            quota.providerTitle = agent.title
            return quota
        }
    }

    /// When the next automatic fetch for this harness's first source may happen.
    func nextAllowedFetch(for harnessId: String) -> Date? {
        guard let first = chain(for: harnessId).first else { return nil }
        let state = sourceStates[first.id] ?? QuotaSourceState()
        let ttl = state.lastAttempt.map { $0.addingTimeInterval(policy.minInterval) }
        return [ttl, state.retryNotBefore].compactMap { $0 }.max()
    }

    /// Test/debug hook: put a reading straight into the store.
    func updateQuota(_ quota: ProviderQuota) {
        quotas[quota.harnessId] = quota
        persist()
    }

    // MARK: Triggers

    /// Refresh the given harnesses (or all eligible), each source subject to the throttle.
    func refresh(_ harnessIds: [String]? = nil, reason: QuotaRefreshReason) async {
        let ids = harnessIds ?? eligibleAgents().map(\.id)
        let tasks = ids.filter { supportsQuota($0) }.map { id in
            Task { await self.refreshHarness(id, reason: reason) }
        }
        for task in tasks { await task.value }
        if !tasks.isEmpty { onQuotasUpdated?(Array(quotas.values)) }
    }

    /// Fire-and-forget variant for UI handlers.
    func request(_ harnessIds: [String]? = nil, reason: QuotaRefreshReason) {
        Task { await refresh(harnessIds, reason: reason) }
    }

    /// A turn ended for this harness: debounced and coalesced, then an ordinary
    /// throttled refresh of just the harnesses that ran (never forced).
    func noteSessionActivity(harnessId: String) {
        guard supportsQuota(harnessId) else { return }
        pendingEventHarnesses.insert(harnessId)
        debounceTask?.cancel()
        let delay = policy.eventDebounce
        let sleep = self.sleep
        debounceTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let ids = Array(self.pendingEventHarnesses)
            self.pendingEventHarnesses.removeAll()
            await self.refresh(ids, reason: .sessionEvent)
        }
    }

    /// Wait for a pending debounced refresh (tests).
    func flushPendingEvents() async { await debounceTask?.value }

    /// ACP `usage_update` → supplementary info only. Does not trigger any request.
    func recordSessionUsage(harnessId: String, usage: SessionUsage) {
        let supplement = QuotaSessionSupplement(
            usedTokens: usage.used, contextTokens: usage.size,
            costAmount: usage.costAmount, costCurrency: usage.costCurrency, reportedAt: now()
        )
        if let old = supplements[harnessId], old.usedTokens == supplement.usedTokens,
           old.contextTokens == supplement.contextTokens, old.costAmount == supplement.costAmount { return }
        supplements[harnessId] = supplement
        if var quota = quotas[harnessId] {
            quota.supplement = supplement
            quotas[harnessId] = quota
        }
    }

    // MARK: Internals

    private func eligibleAgents() -> [AgentProfile] {
        agentsProvider().filter { supportsQuota($0.id) }
    }

    private func chain(for harnessId: String) -> [any QuotaSource] {
        config.sourceIds(for: harnessId).compactMap { sources[$0] }
    }

    private func agentProfile(for harnessId: String) -> AgentProfile {
        agentsProvider().first { $0.id == harnessId }
            ?? AgentProfile(id: harnessId, title: harnessId, subtitle: "", command: "", arguments: [], builtIn: false, notes: "")
    }

    private func refreshHarness(_ harnessId: String, reason: QuotaRefreshReason) async {
        if let running = harnessInFlight[harnessId] {
            await running.value
            return
        }
        let task = Task { @MainActor in await self.runChain(harnessId, reason: reason) }
        harnessInFlight[harnessId] = task
        await task.value
        harnessInFlight[harnessId] = nil
    }

    static func status(forError kind: String) -> ProviderQuota.Status {
        kind == "notConfigured" || kind == "unauthorized" ? .notSignedIn : .error
    }

    private func runChain(_ harnessId: String, reason: QuotaRefreshReason) async {
        let agent = agentProfile(for: harnessId)
        var chosen: (ProviderQuota, any QuotaSource)?
        var lastError: QuotaFetchError?
        /// The first source's failure says what the user can fix (e.g. "not signed in"),
        /// even when a fallback source then fails for a less useful reason.
        var preferredError: QuotaFetchError?
        var fetchedAny = false
        for source in chain(for: harnessId) {
            let state = sourceStates[source.id] ?? QuotaSourceState()
            guard state.allowsFetch(reason: reason, now: now(), policy: policy) else {
                if let cached = sourceCache[source.id] {
                    chosen = (cached, source)
                    break
                }
                if let error = state.lastError { lastError = lastError ?? errorFromKind(error) }
                continue
            }
            fetchedAny = true
            switch await fetchSource(source, agent: agent) {
            case .success(let quota):
                chosen = (quota, source)
            case .failure(let error):
                lastError = error
                if source.id == chain(for: harnessId).first?.id { preferredError = error }
                continue
            }
            break
        }
        let sourcesInOrder = chain(for: harnessId)
        if chosen == nil {
            // Every fetch failed: fall back to the newest cached reading we have.
            chosen = sourcesInOrder.lazy.compactMap { source in self.sourceCache[source.id].map { ($0, source) } }.first
        }
        if let picked = chosen {
            let (reading, source) = picked
            var display = reading
            display.harnessId = harnessId
            display.providerTitle = agent.title
            display.sourceId = source.id
            display.sourceKind = source.kind
            for index in display.windows.indices where source.kind.isEstimate {
                display.windows[index].source = source.kind
            }
            // Cached data while its source (or the preferred source) is failing: keep
            // showing it, flagged stale with the reason.
            let failure = sourceStates[source.id]?.lastError
                ?? (source.id != sourcesInOrder.first?.id ? lastError?.kind : nil)
            display.status = failure == nil ? .ok : .stale
            display.statusDetail = failure
            display.supplement = supplements[harnessId]
            quotas[harnessId] = display
        } else if let lastError, fetchedAny || quotas[harnessId] == nil {
            var failed = quotas[harnessId]
                ?? .placeholder(harnessId: harnessId, title: agent.title, status: .ok)
            failed.providerTitle = agent.title
            let cause = preferredError ?? lastError
            failed.status = failed.hasData ? .stale : Self.status(forError: cause.kind)
            failed.statusDetail = cause.kind
            failed.supplement = supplements[harnessId]
            quotas[harnessId] = failed
        }
        if fetchedAny { persist() }
    }

    private func errorFromKind(_ kind: String) -> QuotaFetchError {
        switch kind {
        case "notConfigured": return .notConfigured
        case "rateLimited": return .rateLimited(retryAfter: nil)
        case "unauthorized": return .unauthorized(401)
        case "unavailable": return .unavailable
        default: return .network(kind)
        }
    }

    /// Single-flight per source id: concurrent callers share one network request.
    private func fetchSource(_ source: any QuotaSource, agent: AgentProfile) async -> Result<ProviderQuota, QuotaFetchError> {
        if let running = sourceInFlight[source.id] { return await running.value }
        let harnessId = agent.id
        isRefreshing[harnessId] = true
        fetchCount += 1
        let task = Task<Result<ProviderQuota, QuotaFetchError>, Never> {
            do { return .success(try await source.fetch(for: agent)) }
            catch { return .failure(HarnessQuotaFetcher.transportError(error)) }
        }
        sourceInFlight[source.id] = task
        let result = await task.value
        sourceInFlight[source.id] = nil
        isRefreshing[harnessId] = false
        var state = sourceStates[source.id] ?? QuotaSourceState()
        switch result {
        case .success(let quota):
            state.recordSuccess(at: now())
            sourceCache[source.id] = quota
        case .failure(let error):
            state.recordFailure(error, at: now(), policy: policy)
        }
        sourceStates[source.id] = state
        return result
    }

    // MARK: Disk cache

    private struct CacheFile: Codable {
        /// 2 = unified `ProviderQuota`. Older files are ignored (next panel open refetches).
        var version = 2
        var quotas: [String: ProviderQuota]
        var sourceCache: [String: ProviderQuota]
        var sourceStates: [String: QuotaSourceState]
    }

    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(CacheFile.self, from: data), file.version == 2 else { return }
        quotas = file.quotas
        sourceCache = file.sourceCache
        sourceStates = file.sourceStates
    }

    private func persist() {
        guard let url = cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var stored = quotas
        for key in stored.keys { stored[key]?.supplement = nil }
        let file = CacheFile(quotas: stored, sourceCache: sourceCache, sourceStates: sourceStates)
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
