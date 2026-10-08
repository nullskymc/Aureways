import XCTest
@testable import Aureways

/// Title bar glass geometry: native controls come from the window edges, tab
/// capsules from a resize-invariant page report.
@MainActor
final class TitlebarGlassTests: XCTestCase {
    private let lights = CGRect(x: 20, y: 19, width: 52, height: 14)

    func testFixedControlsFollowTrafficLightsAndRightEdge() {
        let side = TitlebarMetrics.sidebarFrame(lights: lights, fullscreen: false, headerHeight: 52)
        XCTAssertEqual(side, CGRect(x: 84, y: 11, width: 30, height: 30), "beside the zoom button, centred on the lights")
        XCTAssertEqual(side.midY, lights.midY)
        XCTAssertEqual(TitlebarMetrics.sidebarFrame(lights: lights, fullscreen: true, headerHeight: 44),
                       CGRect(x: 12, y: 7, width: 30, height: 30), "full screen: lights hidden")
        XCTAssertEqual(TitlebarMetrics.rightFrame(width: 1200, centerY: side.midY), CGRect(x: 1120, y: 11, width: 68, height: 30))
        let insets = TitlebarMetrics.insets(sidebar: side, width: 1200)
        XCTAssertEqual(insets.leading, 122)
        XCTAssertEqual(insets.trailing, 88)
    }

    func testTabCapsuleReportIsResizeInvariant() {
        // Page at 1000 pt: strip left 650 in a column with 35 % of the free width before it.
        let report = TabCapsule(base: 650 - 0.35 * 1000, share: 0.35, y: 11, width: 240, height: 30, activeX: 2, activeWidth: 120)
        XCTAssertEqual(report.frame(hostWidth: 1000).minX, 650)
        // Same report, window now 1200 pt: the page would lay the strip out at 720.
        XCTAssertEqual(report.frame(hostWidth: 1200).minX, 720)
        XCTAssertEqual(report.frame(hostWidth: 1200.5, scale: 2).minX, 720)
        XCTAssertEqual(report.activeFrame(), CGRect(x: 2, y: 2, width: 120, height: 26))
        var scrolled = report
        scrolled.activeX = 180
        XCTAssertEqual(scrolled.activeFrame(), CGRect(x: 180, y: 2, width: 58, height: 26), "clipped to the capsule")
        scrolled.activeX = 400
        XCTAssertNil(scrolled.activeFrame(), "scrolled out of view")
    }

    func testSidebarToggleJumpsToTheRememberedLayoutWithoutWaitingForThePage() {
        let layer = TabCapsuleLayer(frame: CGRect(x: 0, y: 0, width: 1200, height: 52))
        let closed = [TabCapsule(base: 160, share: 0, y: 11, width: 90, height: 30, activeX: 2, activeWidth: 86)]
        let open = [TabCapsule(base: 266, share: 0, y: 11, width: 90, height: 30, activeX: 2, activeWidth: 86)]
        layer.apply(closed, sidebarOpen: false)
        layer.apply(open, sidebarOpen: true)
        layer.sidebarWillToggle(to: false)
        XCTAssertEqual(layer.strips, closed)
        // Tabs changed since that layout was seen: wait for the page instead.
        layer.apply([TabCapsule(base: 266, share: 0, y: 11, width: 270, height: 30, activeX: 2, activeWidth: 86)], sidebarOpen: true)
        layer.sidebarWillToggle(to: false)
        XCTAssertEqual(layer.strips.first?.width, 270)
    }
}
