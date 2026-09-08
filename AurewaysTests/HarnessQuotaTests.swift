import Foundation
import XCTest
@testable import Aureways

final class HarnessQuotaTests: XCTestCase {

    func testHarnessQuotaSeverityCalculations() {
        let healthyWindow = HarnessQuotaWindow(id: "1", title: "5h", usedPercent: 42.0)
        XCTAssertEqual(healthyWindow.severity, .healthy)
        XCTAssertEqual(healthyWindow.remainingPercent, 58.0)

        let warningWindow = HarnessQuotaWindow(id: "2", title: "5h", usedPercent: 85.0)
        XCTAssertEqual(warningWindow.severity, .warning)
        XCTAssertEqual(warningWindow.remainingPercent, 15.0)

        let criticalWindow = HarnessQuotaWindow(id: "3", title: "5h", usedPercent: 96.0)
        XCTAssertEqual(criticalWindow.severity, .critical)
        XCTAssertEqual(criticalWindow.remainingPercent, 4.0)

        let snapshot = HarnessQuotaSnapshot(
            harnessId: "codex",
            providerTitle: "Codex",
            primaryWindow: warningWindow,
            secondaryWindow: criticalWindow,
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.overallSeverity, .critical)
    }

    func testCountdownDescriptionFormatting() {
        let now = Date()
        let futureDate = now.addingTimeInterval(3600 * 2 + 60 * 15) // 2h 15m
        let window = HarnessQuotaWindow(id: "test", title: "Session", usedPercent: 50.0, resetsAt: futureDate)
        let desc = window.countdownDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.contains("小时") == true)
        XCTAssertTrue(desc?.contains("分") == true)

        let pastDate = now.addingTimeInterval(-60)
        let pastWindow = HarnessQuotaWindow(id: "test", title: "Session", usedPercent: 50.0, resetsAt: pastDate)
        XCTAssertEqual(pastWindow.countdownDescription, "已重置")
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
        XCTAssertFalse(HarnessQuotaFetcher.supportsQuota(for: "claude"))
        XCTAssertFalse(HarnessQuotaFetcher.supportsQuota(for: "claude-code"))
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

    func testNativeAntigravityQuotaSummaryParsing() {
        let jsonStr = """
        {"response":{"groups":[{"displayName":"Gemini Models", "description":"Models within this group: Gemini Flash, Gemini Pro", "buckets":[{"bucketId":"gemini-weekly", "displayName":"Weekly Limit Remaining", "description":"You have used some of your weekly limit, it will fully refresh in 6 days, 21 hours.", "window":"weekly", "remainingFraction":0.8831848, "resetTime":"2026-09-14T01:05:37Z"}, {"bucketId":"gemini-5h", "displayName":"Five Hour Limit Remaining", "description":"You have used some of your 5-hour limit, it will fully refresh in 2 hours, 57 minutes.", "window":"5h", "remainingFraction":0.2991086, "resetTime":"2026-09-07T06:05:37Z"}]}, {"displayName":"Claude and GPT models", "description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS", "buckets":[{"bucketId":"3p-weekly", "displayName":"Weekly Limit Remaining", "window":"weekly", "remainingFraction":1, "resetTime":"2026-09-14T03:08:12Z"}, {"bucketId":"3p-5h", "displayName":"Five Hour Limit Remaining", "window":"5h", "remainingFraction":1, "resetTime":"2026-09-07T08:08:12Z"}]}]}}
        """
        guard let data = jsonStr.data(using: .utf8) else {
            XCTFail("Failed to convert JSON to data")
            return
        }

        let parsed = HarnessQuotaFetcher.parseAntigravityQuotaSummary(data, agentId: "antigravity")
        XCTAssertNotNil(parsed)
        guard let (primary, secondary, extras) = parsed else {
            XCTFail("Parsed returned nil")
            return
        }

        // Primary: Gemini 5-hour (remaining 0.299 -> used ~70.089%, remaining ~29.91%)
        XCTAssertNotNil(primary)
        XCTAssertEqual(primary?.title, "Gemini 5-hour")
        XCTAssertEqual(round(primary!.usedPercent), 70.0)
        XCTAssertEqual(round(primary!.remainingPercent), 30.0)

        // Secondary: Gemini Weekly (remaining 0.883 -> used ~11.68%, remaining ~88.32%)
        XCTAssertNotNil(secondary)
        XCTAssertEqual(secondary?.title, "Gemini Weekly")
        XCTAssertEqual(round(secondary!.usedPercent), 12.0)
        XCTAssertEqual(round(secondary!.remainingPercent), 88.0)

        // Extras: Claude & GPT 5h and Weekly
        XCTAssertEqual(extras.count, 2)
        XCTAssertEqual(extras[0].title, "Claude & GPT Weekly")
        XCTAssertEqual(extras[1].title, "Claude & GPT 5-hour")
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
    func testQuotaServiceSnapshotManagement() async {
        let service = HarnessQuotaService(loadPersisted: false)
        let agent = AgentProfile(id: "test-agent", title: "Test Agent", subtitle: "Testing", command: "echo", arguments: [], builtIn: false, notes: "")
        XCTAssertNil(service.snapshot(for: agent.id))

        let fakeSnapshot = HarnessQuotaSnapshot(
            harnessId: agent.id,
            providerTitle: agent.title,
            planType: "Pro",
            accountEmail: "test@example.com",
            primaryWindow: HarnessQuotaWindow(id: "p", title: "5h", usedPercent: 20.0),
            updatedAt: Date()
        )
        service.updateSnapshot(fakeSnapshot)

        let retrieved = service.snapshot(for: agent.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.accountEmail, "test@example.com")
        XCTAssertEqual(retrieved?.shortSummary, "80%")
    }

    func testGrokSnapshotWithBreakdown() {
        let weekly = HarnessQuotaWindow(id: "grok-weekly", title: "共享周限额 (Weekly)", usedPercent: 95.0)
        let build = HarnessQuotaBreakdownItem(id: "grok-build", title: "Grok Build", usedPercent: 86.0)
        let chat = HarnessQuotaBreakdownItem(id: "grok-chat", title: "Grok Chat", usedPercent: 8.0)
        let imagine = HarnessQuotaBreakdownItem(id: "grok-imagine", title: "Grok Imagine", usedPercent: 1.0)

        let snapshot = HarnessQuotaSnapshot(
            harnessId: "grok-build",
            providerTitle: "Grok Build",
            planType: "SuperGrok",
            accountEmail: "user@example.com",
            primaryWindow: weekly,
            secondaryWindow: nil,
            extraWindows: [],
            usageBreakdown: [build, chat, imagine],
            creditsRemaining: nil,
            creditsUnit: nil,
            resetCreditsAvailable: nil,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.overallSeverity, .critical)
        XCTAssertEqual(snapshot.mostUrgentWindow?.usedPercent, 95.0)
        XCTAssertEqual(snapshot.shortSummary, "5%")
        XCTAssertEqual(snapshot.usageBreakdown.count, 3)
        XCTAssertEqual(snapshot.usageBreakdown[0].usedPercent, 86.0)
    }

    func testCodexSnapshotParsing() {
        let primary = HarnessQuotaWindow(id: "codex-primary", title: "主限额 (Session)", usedPercent: 94.0, resetsAt: Date(timeIntervalSince1970: 1789973276))
        let snapshot = HarnessQuotaSnapshot(
            harnessId: "codex",
            providerTitle: "Codex",
            planType: "Free",
            accountEmail: "wsz180523@gmail.com",
            primaryWindow: primary,
            secondaryWindow: nil,
            extraWindows: [],
            usageBreakdown: [],
            creditsRemaining: 1890.5,
            creditsUnit: "Credits",
            resetCreditsAvailable: 1,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.overallSeverity, .warning)
        XCTAssertEqual(snapshot.accountEmail, "wsz180523@gmail.com")
        XCTAssertEqual(snapshot.shortSummary, "6%")
        XCTAssertEqual(snapshot.creditsRemaining, 1890.5)
        XCTAssertEqual(snapshot.resetCreditsAvailable, 1)
    }
}
