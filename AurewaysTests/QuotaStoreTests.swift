import XCTest
@testable import Aureways

/// Scriptable source: counts fetches, optional latency, queued results.
private final class FakeSource: QuotaSource, @unchecked Sendable {
    let id: String
    let kind: QuotaSourceKind
    private let lock = NSLock()
    private var _calls = 0
    private var results: [Result<Double, QuotaFetchError>]
    var delay: TimeInterval = 0

    init(id: String, kind: QuotaSourceKind = .officialAPI, results: [Result<Double, QuotaFetchError>] = [.success(10)]) {
        self.id = id
        self.kind = kind
        self.results = results
    }

    var calls: Int { lock.withLock { _calls } }

    func setResults(_ new: [Result<Double, QuotaFetchError>]) { lock.withLock { results = new } }

    func fetch(for agent: AgentProfile) async throws -> HarnessQuotaSnapshot {
        let result: Result<Double, QuotaFetchError> = lock.withLock {
            _calls += 1
            return results.count > 1 ? results.removeFirst() : (results.first ?? .success(0))
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let used = try result.get()
        return HarnessQuotaSnapshot(
            harnessId: agent.id, providerTitle: agent.title,
            primaryWindow: HarnessQuotaWindow(id: "p", title: "5h", usedPercent: used), updatedAt: Date()
        )
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class QuotaStoreTests: XCTestCase {
    private var clock: TestClock!
    private var tempDir: URL!

    override func setUp() async throws {
        clock = TestClock()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func agent(_ id: String) -> AgentProfile {
        AgentProfile(id: id, title: id.capitalized, subtitle: "", command: "x", arguments: [], builtIn: false, notes: "")
    }

    private func makeStore(
        _ sources: [FakeSource],
        map: [String: [String]],
        policy: QuotaRequestPolicy = .standard,
        cacheURL: URL? = nil
    ) -> QuotaStore {
        let clock = self.clock!
        let store = QuotaStore(
            policy: policy,
            config: QuotaSourceConfig(map: map),
            sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0 as any QuotaSource) }),
            cacheURL: cacheURL,
            migrateLegacyDefaults: false,
            now: { clock.now }
        )
        let agents = map.keys.sorted().map(agent)
        store.agentsProvider = { agents }
        return store
    }

    // MARK: TTL / cache

    func testAutomaticRefreshRespectsMinInterval() async {
        let source = FakeSource(id: "s")
        let store = makeStore([source], map: ["codex": ["s"]])
        await store.refresh(reason: .launch)
        XCTAssertEqual(source.calls, 1)
        for reason in [QuotaRefreshReason.pageOpened, .menuBarOpened, .appActivated, .poll, .sessionEvent] {
            clock.advance(30)
            await store.refresh(reason: reason)
        }
        XCTAssertEqual(source.calls, 1, "everything inside the 5 min TTL is served from cache")
        clock.advance(300)
        await store.refresh(reason: .poll)
        XCTAssertEqual(source.calls, 2)
        XCTAssertEqual(store.snapshot(for: "codex")?.primaryWindow?.usedPercent, 10)
        XCTAssertEqual(store.snapshot(for: "codex")?.sourceId, "s")
    }

    func testManualRefreshHasShortMinInterval() async {
        let source = FakeSource(id: "s")
        let store = makeStore([source], map: ["codex": ["s"]])
        await store.refresh(["codex"], reason: .manual)
        clock.advance(10)
        await store.refresh(["codex"], reason: .manual)
        XCTAssertEqual(source.calls, 1, "manual clicks within 30 s are coalesced")
        clock.advance(25)
        await store.refresh(["codex"], reason: .manual)
        XCTAssertEqual(source.calls, 2)
        clock.advance(60)
        await store.refresh(["codex"], reason: .poll)
        XCTAssertEqual(source.calls, 2, "manual fetch also resets the automatic TTL")
    }

    func testDiskCacheSurvivesRelaunch() async {
        let url = tempDir.appendingPathComponent("quota-cache.json")
        let source = FakeSource(id: "s", results: [.success(42)])
        let first = makeStore([source], map: ["codex": ["s"]], cacheURL: url)
        await first.refresh(reason: .launch)
        XCTAssertEqual(source.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        clock.advance(120)
        let second = makeStore([source], map: ["codex": ["s"]], cacheURL: url)
        XCTAssertEqual(second.snapshot(for: "codex")?.primaryWindow?.usedPercent, 42, "snapshot restored from disk")
        await second.refresh(reason: .launch)
        XCTAssertEqual(source.calls, 1, "relaunch inside the TTL doesn't refetch")
        clock.advance(200)
        await second.refresh(reason: .launch)
        XCTAssertEqual(source.calls, 2)
    }

    // MARK: Single flight / debounce

    func testSingleFlightDedupesConcurrentRefreshes() async {
        let source = FakeSource(id: "shared")
        source.delay = 0.2
        let store = makeStore([source], map: ["grok": ["shared"], "grok-build": ["shared"]])
        async let a: Void = store.refresh(["grok"], reason: .manual)
        async let b: Void = store.refresh(["grok"], reason: .manual)
        async let c: Void = store.refresh(["grok-build"], reason: .launch)
        async let d: Void = store.refresh(reason: .pageOpened)
        _ = await (a, b, c, d)
        XCTAssertEqual(source.calls, 1, "concurrent callers share one request per source")
        XCTAssertNotNil(store.snapshot(for: "grok"))
        XCTAssertNotNil(store.snapshot(for: "grok-build"))
    }

    func testSessionEventsAreDebouncedAndCoalesced() async {
        let source = FakeSource(id: "s")
        var policy = QuotaRequestPolicy.standard
        policy.eventDebounce = 0.1
        let store = makeStore([source], map: ["codex": ["s"]], policy: policy)
        for _ in 0..<5 { store.noteSessionActivity(harnessId: "codex") }
        XCTAssertEqual(source.calls, 0, "nothing fires before the debounce window")
        await store.flushPendingEvents()
        XCTAssertEqual(source.calls, 1)
        // Another burst inside the TTL: debounced and then skipped by the TTL.
        for _ in 0..<3 { store.noteSessionActivity(harnessId: "codex") }
        await store.flushPendingEvents()
        XCTAssertEqual(source.calls, 1)
        store.noteSessionActivity(harnessId: "unknown-harness")
        await store.flushPendingEvents()
        XCTAssertEqual(source.calls, 1)
    }

    // MARK: Backoff

    func testBackoffGrowsExponentiallyAndCaps() {
        let policy = QuotaRequestPolicy.standard
        var state = QuotaSourceState()
        let t0 = Date(timeIntervalSince1970: 0)
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            state.recordFailure(.network("x"), at: t0, policy: policy)
            delays.append(state.retryNotBefore!.timeIntervalSince(t0))
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 960, 1800, 1800, 1800])
        state.recordSuccess(at: t0)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertNil(state.retryNotBefore)
    }

    func testFailureBacksOffAutomaticRefreshes() async {
        let source = FakeSource(id: "s", results: [.failure(.http(500)), .failure(.http(500)), .success(5)])
        var policy = QuotaRequestPolicy.standard
        policy.minInterval = 10 // isolate backoff from the TTL
        let store = makeStore([source], map: ["codex": ["s"]], policy: policy)
        await store.refresh(reason: .launch)
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(store.snapshot(for: "codex")?.error, "http 500")
        clock.advance(59)
        await store.refresh(reason: .poll)
        XCTAssertEqual(source.calls, 1, "inside the 60 s backoff")
        clock.advance(2)
        await store.refresh(reason: .poll)
        XCTAssertEqual(source.calls, 2)
        clock.advance(119)
        await store.refresh(reason: .poll)
        XCTAssertEqual(source.calls, 2, "second failure doubles the backoff to 120 s")
        clock.advance(2)
        await store.refresh(reason: .poll)
        XCTAssertEqual(source.calls, 3)
        XCTAssertNil(store.snapshot(for: "codex")?.error)
        XCTAssertEqual(store.sourceStates["s"]?.consecutiveFailures, 0)
    }

    func testRateLimitHonorsRetryAfterEvenForManual() async {
        let source = FakeSource(id: "s", results: [.success(1), .failure(.rateLimited(retryAfter: 900)), .success(2)])
        let store = makeStore([source], map: ["codex": ["s"]])
        await store.refresh(reason: .launch)
        clock.advance(31)
        await store.refresh(["codex"], reason: .manual)
        XCTAssertEqual(source.calls, 2)
        let snapshot = store.snapshot(for: "codex")
        XCTAssertEqual(snapshot?.error, "rateLimited")
        XCTAssertEqual(snapshot?.primaryWindow?.usedPercent, 1, "keeps showing the cached reading")
        clock.advance(600)
        await store.refresh(["codex"], reason: .manual)
        XCTAssertEqual(source.calls, 2, "manual can't punch through a 429 window")
        clock.advance(301)
        await store.refresh(["codex"], reason: .manual)
        XCTAssertEqual(source.calls, 3)
        XCTAssertEqual(store.snapshot(for: "codex")?.primaryWindow?.usedPercent, 2)
        XCTAssertNil(store.snapshot(for: "codex")?.error)
    }

    func testManualMayRetryPlainFailureAfterShortInterval() async {
        let source = FakeSource(id: "s", results: [.failure(.notConfigured), .success(3)])
        let store = makeStore([source], map: ["codex": ["s"]])
        await store.refresh(reason: .launch)
        XCTAssertNil(store.snapshot(for: "codex"), "no login isn't shown as a scary error card")
        clock.advance(600)
        await store.refresh(reason: .poll)
        XCTAssertEqual(source.calls, 1, "not-configured backs off for 30 min automatically")
        await store.refresh(["codex"], reason: .manual)
        XCTAssertEqual(source.calls, 2, "user logged in and clicked refresh")
        XCTAssertEqual(store.snapshot(for: "codex")?.primaryWindow?.usedPercent, 3)
    }

    func testRetryAfterHeaderParsing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(HarnessQuotaFetcher.parseRetryAfter("120", now: now), 120)
        XCTAssertNil(HarnessQuotaFetcher.parseRetryAfter(nil, now: now))
        XCTAssertNil(HarnessQuotaFetcher.parseRetryAfter("soon", now: now))
        let http = HarnessQuotaFetcher.parseRetryAfter("Tue, 14 Nov 2023 22:15:20 GMT", now: now)
        XCTAssertEqual(http ?? -1, 120, accuracy: 1)
    }

    // MARK: Polling / lifecycle

    func testPollingOnlyWhileAppActive() async {
        let source = FakeSource(id: "s")
        let store = makeStore([source], map: ["codex": ["s"]])
        await store.pollTick()
        XCTAssertEqual(source.calls, 0, "inactive app (menu bar only) never polls")
        XCTAssertFalse(store.isPolling)
        store.setAppActive(true)
        XCTAssertTrue(store.isPolling)
        store.setAppActive(false)
        XCTAssertFalse(store.isPolling)
        await store.pollTick()
        // The activation stale-check may have fetched once; polling itself added nothing.
        XCTAssertLessThanOrEqual(source.calls, 1)
    }

    // MARK: Config / sources

    func testMappingComesFromConfigAndFallsBack() async {
        let api = FakeSource(id: "api", results: [.failure(.unauthorized(401))])
        let log = FakeSource(id: "log", kind: .localCache, results: [.success(77)])
        let store = makeStore([api, log], map: ["codex": ["api", "log"], "claude": []])
        XCTAssertFalse(store.supportsQuota("claude"), "empty list disables a harness")
        XCTAssertFalse(store.supportsQuota("opencode"))
        await store.refresh(reason: .launch)
        let snapshot = store.snapshot(for: "codex")
        XCTAssertEqual(snapshot?.primaryWindow?.usedPercent, 77)
        XCTAssertEqual(snapshot?.sourceId, "log")
        XCTAssertEqual(snapshot?.sourceKind, .localCache)
        XCTAssertEqual(snapshot?.error, "unauthorized", "fallback data carries why the preferred source failed")
        XCTAssertEqual(api.calls, 1)
        XCTAssertEqual(log.calls, 1)
    }

    func testConfigOverridesParse() {
        let overrides = QuotaSourceConfig.parseOverrides(["codex": ["codex.session-log"], "claude": "", "x": "grok.billing"])
        let config = QuotaSourceConfig.builtIn.merging(overrides)
        XCTAssertEqual(config.sourceIds(for: "codex"), ["codex.session-log"])
        XCTAssertEqual(config.sourceIds(for: "claude"), [])
        XCTAssertEqual(config.sourceIds(for: "x"), ["grok.billing"])
        XCTAssertEqual(config.sourceIds(for: "grok-build"), ["grok.billing"])
        let json = QuotaSourceConfig.parseOverrides(#"{"codex":["a","b"]}"#)
        XCTAssertEqual(json["codex"], ["a", "b"])
        for ids in QuotaSourceConfig.builtIn.map.values {
            for id in ids { XCTAssertNotNil(QuotaSourceRegistry.builtIn[id], "unknown source \(id)") }
        }
    }

    func testSessionUsageIsSupplementaryOnly() async throws {
        let source = FakeSource(id: "s")
        let store = makeStore([source], map: ["codex": ["s"]])
        let usage = try XCTUnwrap(SessionUsage(json: .object(["used": .number(1200), "size": .number(200_000)])))
        store.recordSessionUsage(harnessId: "codex", usage: usage)
        XCTAssertEqual(source.calls, 0, "ACP usage never triggers a request")
        await store.refresh(reason: .launch)
        XCTAssertEqual(store.snapshot(for: "codex")?.supplement?.usedTokens, 1200)
        XCTAssertEqual(store.snapshot(for: "codex")?.primaryWindow?.usedPercent, 10, "limits still come from the source")
    }

    func testCodexRolloutLineParsing() throws {
        let line = #"{"timestamp":"2026-10-02T04:40:34.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":10,"window_minutes":10080,"resets_at":1790000000},"plan_type":"plus"}}}"#
        let snapshot = try XCTUnwrap(CodexSessionLogSource.parseRolloutLine(Data(line.utf8), agent: agent("codex")))
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 42.5)
        XCTAssertEqual(snapshot.primaryWindow?.windowMinutes, 300)
        XCTAssertEqual(snapshot.primaryWindow?.resetsAt?.timeIntervalSince(snapshot.updatedAt) ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(snapshot.secondaryWindow?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(snapshot.planType, "Plus")
        let empty = #"{"payload":{"rate_limits":{"primary":null,"secondary":null}}}"#
        XCTAssertNil(CodexSessionLogSource.parseRolloutLine(Data(empty.utf8), agent: agent("codex")))
    }

    func testCodexSessionLogSourceReadsNewestFile() async throws {
        let now = Date()
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        let dir = tempDir.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-10-02T04:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300}}}}"#,
            #"{"timestamp":"2026-10-02T04:10:00Z","payload":{"type":"agent_message"}}"#,
            #"{"timestamp":"2026-10-02T04:20:00Z","payload":{"rate_limits":{"primary":{"used_percent":9,"window_minutes":300}}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        let source = CodexSessionLogSource(home: tempDir.path)
        let snapshot = try await source.fetch(for: agent("codex"))
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 9)
        let missing = CodexSessionLogSource(home: tempDir.appendingPathComponent("nope").path)
        do {
            _ = try await missing.fetch(for: agent("codex"))
            XCTFail("expected notConfigured")
        } catch let error as QuotaFetchError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    func testClaudeUsageParsing() throws {
        let body = #"{"five_hour":{"utilization":37.0,"resets_at":"2026-10-03T10:00:00Z"},"seven_day":{"utilization":12,"resets_at":"2026-10-08T00:00:00+00:00"},"seven_day_opus":null}"#
        let snapshot = try ClaudeOAuthUsageSource.parseUsage(Data(body.utf8), agent: agent("claude"), plan: "max")
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 37)
        XCTAssertNotNil(snapshot.primaryWindow?.resetsAt)
        XCTAssertEqual(snapshot.secondaryWindow?.usedPercent, 12)
        XCTAssertTrue(snapshot.extraWindows.isEmpty)
        XCTAssertEqual(snapshot.planType, "Max")
        XCTAssertEqual(ClaudeOAuthUsageSource.extractToken(["claudeAiOauth": ["accessToken": "t", "subscriptionType": "pro"]])?.token, "t")
        XCTAssertNil(ClaudeOAuthUsageSource.extractToken(["claudeAiOauth": [:]]))
        XCTAssertThrowsError(try ClaudeOAuthUsageSource.parseUsage(Data("{}".utf8), agent: agent("claude"), plan: nil))
    }
}
