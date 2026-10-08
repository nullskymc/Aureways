import Foundation
import XCTest
@testable import Aureways

final class HarnessQuotaTests: XCTestCase {

    func testQuotaLevelBands() {
        // Remaining > 50 green, 20–50 orange, < 20 red.
        XCTAssertEqual(QuotaWindow(id: "1", label: "5h", usedPercent: 42).level, .ample)
        XCTAssertEqual(QuotaWindow(id: "1", label: "5h", usedPercent: 42).remainingPercent, 58)
        XCTAssertEqual(QuotaWindow(id: "2", label: "5h", usedPercent: 50).level, .moderate)
        XCTAssertEqual(QuotaWindow(id: "3", label: "5h", usedPercent: 80).level, .moderate)
        XCTAssertEqual(QuotaWindow(id: "4", label: "5h", usedPercent: 85).level, .low)
        XCTAssertEqual(QuotaWindow(id: "5", label: "5h", usedPercent: 120).remainingPercent, 0)
        XCTAssertEqual(QuotaWindow(id: "6", label: "Credits", balance: 12).level, .unknown)
        XCTAssertNil(QuotaWindow(id: "6", label: "Credits", balance: 12).remainingPercent)
        XCTAssertEqual(QuotaWindow(id: "6", label: "Credits", balance: 12).kind, .credits)
        // used / limit when there's no percentage.
        XCTAssertEqual(QuotaWindow(id: "7", label: "Monthly", used: 30, limit: 120).remainingPercent, 75)
        XCTAssertEqual(QuotaWindow(id: "8", label: "x", windowMinutes: 300).kind, .session)
        XCTAssertEqual(QuotaWindow(id: "8", label: "x", windowMinutes: 10080).kind, .weekly)
        XCTAssertEqual(QuotaWindow(id: "8", label: "x", windowMinutes: 43200).kind, .monthly)
    }

    func testTightestWindowAndStatus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = ProviderQuota(
            harnessId: "codex", providerTitle: "Codex",
            windows: [
                QuotaWindow(id: "p", label: "5h", usedPercent: 85, resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(id: "s", label: "Weekly", usedPercent: 96, resetsAt: now.addingTimeInterval(86400), source: .localEstimate),
                QuotaWindow(id: "c", label: "Credits", balance: 5),
            ],
            lastUpdated: now
        )
        XCTAssertEqual(quota.tightestWindow?.id, "s")
        XCTAssertEqual(quota.remainingPercent ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(quota.level, .low)
        XCTAssertTrue(quota.isEstimated, "the tightest window is a local estimate")
        XCTAssertEqual(quota.effectiveStatus(now: now), .ok)
        XCTAssertTrue(quota.windows[0].hasReset(now: now.addingTimeInterval(2 * 3600)))
        XCTAssertEqual(quota.effectiveStatus(now: now.addingTimeInterval(2 * 3600)), .ok, "the 5h window rolled over, but the tightest (weekly) reading still holds")
        XCTAssertEqual(quota.effectiveStatus(now: now.addingTimeInterval(86400 + 60)), .stale, "the tightest window reset since the reading")
        XCTAssertEqual(quota.effectiveStatus(now: now.addingTimeInterval(25 * 3600)), .stale)
        XCTAssertEqual(quota.shortSummary, "4%")

        let placeholder = ProviderQuota.placeholder(harnessId: "cursor", title: "Cursor", status: .unsupported)
        XCTAssertNil(placeholder.tightestWindow)
        XCTAssertEqual(placeholder.level, .unknown)
        XCTAssertEqual(placeholder.effectiveStatus(now: now), .unsupported)
    }

    func testProviderQuotaRoundTripsAndReadsOldSourceKind() throws {
        let quota = ProviderQuota(
            harnessId: "grok-build", providerTitle: "Grok Build", plan: "SuperGrok",
            windows: [QuotaWindow(id: "w", label: "Weekly", usedPercent: 30, shares: [QuotaShare(id: "b", title: "Grok Build", usedPercent: 28)])],
            status: .stale, statusDetail: "network", lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), sourceKind: .localEstimate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let back = try decoder.decode(ProviderQuota.self, from: encoder.encode(quota))
        XCTAssertEqual(back, quota)
        XCTAssertEqual(try decoder.decode(QuotaSourceKind.self, from: Data(#""localCache""#.utf8)), .localEstimate)
    }

    func testRetiredMenuBarQuotaSettingIsDropped() throws {
        let suite = "aureways.tests.retired.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("always", forKey: "menuBarQuotaIndicator")
        defaults.set(true, forKey: "quotaNotifications")
        RetiredDefaults.remove(from: defaults)
        XCTAssertNil(defaults.object(forKey: "menuBarQuotaIndicator"), "old menu bar percentage setting is gone")
        XCTAssertEqual(defaults.object(forKey: "quotaNotifications") as? Bool, true, "other settings untouched")
        RetiredDefaults.remove(from: defaults)
    }

    func testCodexDateParsing() {
        // Test UNIX timestamp numeric parsing
        let epochDate = HarnessQuotaFetcher.parseDate(1789973276)
        XCTAssertNotNil(epochDate)

        // Test ISO8601 parsing
        let isoDate = HarnessQuotaFetcher.parseDate("2026-09-07T06:05:37Z")
        XCTAssertNotNil(isoDate)
    }

    func testProviderMapping() {
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("codex"), "codex")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("antigravity"), "antigravity")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("gemini"), "antigravity")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("grok"), "grok")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("grok-build"), "grok")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("claude"), "claude")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("claude-code"), "claude")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("cursor"), "cursor")
        XCTAssertEqual(HarnessQuotaFetcher.mapAgentIdToProvider("cursor-agent"), "cursor")

        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "codex"))
        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "grok"))
        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "grok-build"))
        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "antigravity"))
        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "gemini"))
        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "claude"))
        XCTAssertTrue(HarnessQuotaFetcher.supportsQuota(for: "claude-code"))
        XCTAssertFalse(HarnessQuotaFetcher.supportsQuota(for: "cursor"))
        XCTAssertFalse(HarnessQuotaFetcher.supportsQuota(for: "copilot"))
        XCTAssertFalse(HarnessQuotaFetcher.supportsQuota(for: "opencode"))
    }

    func testAntigravityProcessMatching() {
        XCTAssertTrue(HarnessQuotaFetcher.isAntigravityProcess(
            "421 /Applications/Antigravity.app/Contents/MacOS/language_server --extension_server_port=9210"
        ))
        XCTAssertTrue(HarnessQuotaFetcher.isAntigravityProcess("99 /usr/local/bin/agy --csrf_token=abc"))
        XCTAssertTrue(HarnessQuotaFetcher.isAntigravityProcess("12 cloudcode --port 8080"))
        XCTAssertFalse(HarnessQuotaFetcher.isAntigravityProcess("55 /usr/local/bin/typescript-language-server --stdio"))
        XCTAssertFalse(HarnessQuotaFetcher.isAntigravityProcess("8 node language_server.js"))
        XCTAssertFalse(HarnessQuotaFetcher.isAntigravityProcess("12 /bin/zsh -c strategy"))
        XCTAssertFalse(HarnessQuotaFetcher.isAntigravityProcess(
            "3349 /Users/me/.local/share/antigravity-acp/agy_acp_server.par"
        ))
    }

    func testAntigravityACPCredentialExtraction() {
        let fileBlob: [String: Any] = [
            "client_id": "client-1",
            "client_secret": "secret-1",
            "refresh_token": "refresh-1",
            "token_uri": "https://oauth2.googleapis.com/token",
            "project_id": "aicode-consumers",
        ]
        let creds = HarnessQuotaFetcher.extractAntigravityACPCredentials(fileBlob)
        XCTAssertEqual(creds?.clientId, "client-1")
        XCTAssertEqual(creds?.clientSecret, "secret-1")
        XCTAssertEqual(creds?.refreshToken, "refresh-1")
        XCTAssertEqual(creds?.tokenURI, "https://oauth2.googleapis.com/token")
        XCTAssertNil(creds?.accessToken)

        let nested: [String: Any] = [
            "token": [
                "client_id": "client-2",
                "client_secret": "secret-2",
                "refresh_token": "refresh-2",
                "access_token": "access-2",
            ]
        ]
        let nestedCreds = HarnessQuotaFetcher.extractAntigravityACPCredentials(nested)
        XCTAssertEqual(nestedCreds?.clientId, "client-2")
        XCTAssertEqual(nestedCreds?.refreshToken, "refresh-2")
        XCTAssertEqual(nestedCreds?.accessToken, "access-2")

        XCTAssertNil(HarnessQuotaFetcher.extractAntigravityACPCredentials(["access_token": "only"]))
        XCTAssertNil(HarnessQuotaFetcher.extractAntigravityACPCredentials([:]))
    }

    func testAntigravityCloudCodeEndpointAndLoadAssistParsing() {
        XCTAssertEqual(
            HarnessQuotaFetcher.antigravityCloudCodeEndpoint(usesGcpTos: false),
            "https://daily-cloudcode-pa.googleapis.com"
        )
        XCTAssertEqual(
            HarnessQuotaFetcher.antigravityCloudCodeEndpoint(usesGcpTos: true),
            "https://cloudcode-pa.googleapis.com"
        )

        let load: [String: Any] = [
            "cloudaicompanionProject": "aicode-consumers",
            "currentTier": ["id": "free-tier", "name": "Antigravity"],
            "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro", "usesGcpTos": false],
        ]
        let parsed = HarnessQuotaFetcher.parseAntigravityLoadCodeAssist(load)
        XCTAssertEqual(parsed.project, "aicode-consumers")
        XCTAssertEqual(parsed.plan, "Google AI Pro")
        XCTAssertFalse(parsed.usesGcpTos)
    }

    func testCodexAuthLayouts() {
        let nested: [String: Any] = [
            "tokens": [
                "access_token": "nested-token",
                "account_id": "acct-1",
                "email": "nested@example.com"
            ]
        ]
        let nestedAuth = HarnessQuotaFetcher.extractCodexAuth(nested)
        XCTAssertEqual(nestedAuth?.token, "nested-token")
        XCTAssertEqual(nestedAuth?.accountId, "acct-1")
        XCTAssertEqual(nestedAuth?.email, "nested@example.com")

        let topLevel: [String: Any] = [
            "access_token": "top-token",
            "account_id": "acct-2",
            "plan_type": "pro"
        ]
        let topAuth = HarnessQuotaFetcher.extractCodexAuth(topLevel)
        XCTAssertEqual(topAuth?.token, "top-token")
        XCTAssertEqual(topAuth?.accountId, "acct-2")
        XCTAssertEqual(topAuth?.planType, "pro")
    }

    func testNativeAntigravityQuotaSummaryParsing() throws {
        let jsonStr = """
        {"response":{"groups":[{"displayName":"Gemini Models", "description":"Models within this group: Gemini Flash, Gemini Pro", "buckets":[{"bucketId":"gemini-weekly", "displayName":"Weekly Limit Remaining", "description":"You have used some of your weekly limit, it will fully refresh in 6 days, 21 hours.", "window":"weekly", "remainingFraction":0.8831848, "resetTime":"2026-09-14T01:05:37Z"}, {"bucketId":"gemini-5h", "displayName":"Five Hour Limit Remaining", "description":"You have used some of your 5-hour limit, it will fully refresh in 2 hours, 57 minutes.", "window":"5h", "remainingFraction":0.2991086, "resetTime":"2026-09-07T06:05:37Z"}]}, {"displayName":"Claude and GPT models", "description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS", "buckets":[{"bucketId":"3p-weekly", "displayName":"Weekly Limit Remaining", "window":"weekly", "remainingFraction":1, "resetTime":"2026-09-14T03:08:12Z"}, {"bucketId":"3p-5h", "displayName":"Five Hour Limit Remaining", "window":"5h", "remainingFraction":1, "resetTime":"2026-09-07T08:08:12Z"}]}]}}
        """
        let windows = try XCTUnwrap(HarnessQuotaFetcher.parseAntigravityQuotaSummary(Data(jsonStr.utf8), agentId: "antigravity"))
        XCTAssertEqual(windows.map(\.label), ["Gemini 5h", "Gemini Weekly", "Claude & GPT Weekly", "Claude & GPT 5h"])
        XCTAssertEqual(windows.map(\.kind), [.session, .weekly, .weekly, .session])
        XCTAssertEqual(round(windows[0].remainingPercent ?? 0), 30)
        XCTAssertEqual(round(windows[1].remainingPercent ?? 0), 88)
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertTrue(windows.allSatisfy { $0.source == .officialAPI })
        let quota = ProviderQuota(harnessId: "antigravity", providerTitle: "Antigravity", windows: windows)
        XCTAssertEqual(quota.tightestWindow?.label, "Gemini 5h")
    }

    func testCloudCodeQuotaSummaryWithoutResponseWrapper() throws {
        let jsonStr = """
        {"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.83,"resetTime":"2026-09-14T01:05:37Z"},{"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.95,"resetTime":"2026-09-09T02:40:48Z"}]}],"description":"shared limits"}
        """
        let windows = try XCTUnwrap(HarnessQuotaFetcher.parseAntigravityQuotaSummary(Data(jsonStr.utf8), agentId: "antigravity"))
        XCTAssertEqual(windows.first?.label, "Gemini 5h")
        XCTAssertEqual(windows.last?.label, "Gemini Weekly")
        XCTAssertEqual(round(windows[0].resolvedUsedPercent ?? 0), 5.0)
        XCTAssertNil(HarnessQuotaFetcher.parseAntigravityQuotaSummary(Data(#"{"groups":[]}"#.utf8), agentId: "antigravity"))
    }

    func testNativeAntigravityUserStatusParsing() {
        let jsonStr = """
        {"userStatus":{"name":"Tom Wu", "email":"wushouzhen1@gmail.com", "userTier":{"id":"g1-pro-tier", "name":"Google AI Pro"}, "planStatus":{"planInfo":{"planName":"Pro"}}}}
        """
        guard let data = jsonStr.data(using: .utf8) else {
            XCTFail("Failed to convert JSON to data")
            return
        }

        let (email, plan, _) = HarnessQuotaFetcher.parseAntigravityUserStatus(data, agentId: "antigravity")
        XCTAssertEqual(email, "wushouzhen1@gmail.com")
        XCTAssertEqual(plan, "Google AI Pro")
    }

    @MainActor
    func testQuotaStoreManualUpdate() async {
        let service = QuotaStore(cacheURL: nil)
        XCTAssertNil(service.quota(for: "test-agent"))
        service.updateQuota(ProviderQuota(
            harnessId: "test-agent", providerTitle: "Test Agent", plan: "Pro", account: "test@example.com",
            windows: [QuotaWindow(id: "p", label: "5h", usedPercent: 20)], lastUpdated: Date()
        ))
        XCTAssertEqual(service.quota(for: "test-agent")?.account, "test@example.com")
        XCTAssertEqual(service.quota(for: "test-agent")?.shortSummary, "80%")
    }

    func testGrokSeparateProductsAreTheirOwnWindows() throws {
        let json = """
        {"config":{"creditUsagePercent":95,"productUsage":[{"product":"GrokBuild","usagePercent":86},{"product":"GrokChat","usagePercent":8},{"product":"GrokImagine","usagePercent":40}]}}
        """
        let agent = AgentProfile(id: "grok-build", title: "Grok Build", subtitle: "", command: "grok", arguments: [], builtIn: true, notes: "")
        let quota = try HarnessQuotaFetcher.parseGrokBilling(Data(json.utf8), agent: agent, email: "user@example.com", planTitle: "SuperGrok")
        XCTAssertEqual(quota.windows.map(\.label), ["Weekly", "Grok Build", "Grok Chat", "Grok Imagine"])
        XCTAssertTrue(quota.windows[0].shares.isEmpty, "not pooled: no shares")
        XCTAssertEqual(quota.tightestWindow?.id, "grok-weekly-window")
        XCTAssertEqual(quota.shortSummary, "5%")
        XCTAssertEqual(quota.level, .low)
        XCTAssertEqual(quota.plan, "SuperGrok")
        XCTAssertEqual(quota.account, "user@example.com")
    }

    func testGrokChatAndBuildShareOnePool() throws {
        let json = """
        {"config":{"creditUsagePercent":30,"isUnifiedBillingUser":true,"productUsage":[{"product":"GrokBuild","usagePercent":28},{"product":"GrokChat","usagePercent":2}],"billingPeriodEnd":"2026-10-08T09:33:42Z"}}
        """
        let agent = AgentProfile(id: "grok-build", title: "Grok Build", subtitle: "", command: "grok", arguments: [], builtIn: true, notes: "")
        let quota = try HarnessQuotaFetcher.parseGrokBilling(
            Data(json.utf8), agent: agent, email: "user@example.com", planTitle: "SuperGrok"
        )
        XCTAssertEqual(quota.windows.count, 1, "one shared limit")
        XCTAssertEqual(quota.windows[0].usedPercent, 30)
        XCTAssertEqual(quota.windows[0].kind, .weekly)
        XCTAssertNotNil(quota.windows[0].resetsAt)
        XCTAssertEqual(quota.shortSummary, "70%")
        XCTAssertEqual(quota.windows[0].shares.map(\.title), ["Grok Build", "Grok Chat"])
        XCTAssertEqual(quota.windows[0].shares.map(\.usedPercent), [28, 2])
    }

    func testGrokPoolsWhenProductPercentsSumToTheCredit() throws {
        let json = """
        {"config":{"creditUsagePercent":30,"productUsage":[{"product":"GrokBuild","usagePercent":28},{"product":"GrokChat","usagePercent":2}]}}
        """
        let agent = AgentProfile(id: "grok-build", title: "Grok Build", subtitle: "", command: "grok", arguments: [], builtIn: true, notes: "")
        let quota = try HarnessQuotaFetcher.parseGrokBilling(
            Data(json.utf8), agent: agent, email: nil, planTitle: "xAI Grok"
        )
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].shares.count, 2)
        XCTAssertThrowsError(try HarnessQuotaFetcher.parseGrokBilling(Data(#"{"config":{}}"#.utf8), agent: agent, email: nil, planTitle: "x"))
    }

    func testCodexUsageFixture() throws {
        let json = """
        {"email":"me@example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":62,"limit_window_seconds":18000,"reset_at":1789973276},"secondary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":1790500000}},"code_review_rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800}},"credits":{"balance":"1890.5","unit":"Credits"},"rate_limit_reset_credits":{"available_count":1}}
        """
        let agent = AgentProfile(id: "codex", title: "Codex", subtitle: "", command: "codex", arguments: [], builtIn: true, notes: "")
        let quota = try HarnessQuotaFetcher.parseCodexUsage(Data(json.utf8), agent: agent, auth: (nil, nil))
        XCTAssertEqual(quota.windows.map(\.label), ["5h", "Weekly", "Code review", "Credits"])
        XCTAssertEqual(quota.windows.map(\.kind), [.session, .weekly, .other, .credits])
        XCTAssertEqual(quota.windows[0].windowMinutes, 300)
        XCTAssertEqual(quota.windows[0].resetsAt, Date(timeIntervalSince1970: 1789973276))
        XCTAssertEqual(quota.windows[3].balance, 1890.5)
        XCTAssertEqual(quota.tightestWindow?.id, "codex-primary")
        XCTAssertEqual(quota.remainingPercent, 38)
        XCTAssertEqual(quota.plan, "Plus")
        XCTAssertEqual(quota.account, "me@example.com")
        XCTAssertEqual(quota.resetCreditsAvailable, 1)
        XCTAssertThrowsError(try HarnessQuotaFetcher.parseCodexUsage(Data("{}".utf8), agent: agent, auth: (nil, nil)))
    }
}
