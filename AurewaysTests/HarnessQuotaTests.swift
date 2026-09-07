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
    }

    @MainActor
    func testQuotaServiceSnapshotManagement() async {
        let service = HarnessQuotaService()
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
        XCTAssertEqual(retrieved?.shortSummary, "20%")
    }

    func testGrokSnapshotWithBreakdown() {
        let weekly = HarnessQuotaWindow(id: "grok-weekly", title: "周限额 (Weekly)", usedPercent: 95.0)
        let build = HarnessQuotaWindow(id: "grok-build", title: "Grok Build", usedPercent: 86.0)
        let chat = HarnessQuotaWindow(id: "grok-chat", title: "Grok Chat", usedPercent: 8.0)

        let snapshot = HarnessQuotaSnapshot(
            harnessId: "grok-build",
            providerTitle: "Grok Build",
            planType: "SuperGrok",
            accountEmail: "user@example.com",
            primaryWindow: weekly,
            secondaryWindow: nil,
            extraWindows: [build, chat],
            creditsRemaining: nil,
            creditsUnit: nil,
            resetCreditsAvailable: nil,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.overallSeverity, .critical)
        XCTAssertEqual(snapshot.mostUrgentWindow?.usedPercent, 95.0)
        XCTAssertEqual(snapshot.shortSummary, "95%")
        XCTAssertEqual(snapshot.extraWindows.count, 2)
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
            creditsRemaining: 1890.5,
            creditsUnit: "Credits",
            resetCreditsAvailable: 1,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.overallSeverity, .warning)
        XCTAssertEqual(snapshot.accountEmail, "wsz180523@gmail.com")
        XCTAssertEqual(snapshot.shortSummary, "94%")
        XCTAssertEqual(snapshot.creditsRemaining, 1890.5)
        XCTAssertEqual(snapshot.resetCreditsAvailable, 1)
    }
}
