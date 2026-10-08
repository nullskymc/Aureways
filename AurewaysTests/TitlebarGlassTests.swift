import XCTest
@testable import Aureways

/// Title bar glass geometry: native controls come from the window edges, tab
/// strips from a resize-invariant page report.
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
        // "+" is its own circle, grouped just left of the toggles (or at the edge without them).
        XCTAssertEqual(TitlebarMetrics.addFrame(width: 1200, centerY: side.midY, besideToggles: true), CGRect(x: 1082, y: 11, width: 30, height: 30))
        XCTAssertEqual(TitlebarMetrics.addFrame(width: 1200, centerY: side.midY, besideToggles: false), CGRect(x: 1158, y: 11, width: 30, height: 30))
        let insets = TitlebarMetrics.insets(sidebar: side, width: 1200)
        XCTAssertEqual(insets.leading, 122)
        XCTAssertEqual(insets.trailing, 126)
        XCTAssertEqual(insets.addOnly, 50)
    }

    func testTabStripReportIsResizeInvariant() {
        // Page at 1000 pt: strip left 650, width 330, in a column with 37.5 % of
        // the free width before it and 25 % of it as its own width.
        let report = TabCapsule(base: 650 - 0.375 * 1000, share: 0.375, y: 13, widthBase: 330 - 0.25 * 1000, widthShare: 0.25,
                                height: 26, activeIndex: 1, count: 3)
        XCTAssertEqual(report.frame(hostWidth: 1000), CGRect(x: 650, y: 13, width: 330, height: 26))
        // Same report, window now 1200 pt: the page would lay the strip out at 725, 380 wide.
        XCTAssertEqual(report.frame(hostWidth: 1200), CGRect(x: 725, y: 13, width: 380, height: 26))
        XCTAssertEqual(report.frame(hostWidth: 1200.5, scale: 2).minX, 725)
        // Equal-width tabs: the platter follows the resize too.
        let tab: CGFloat = (330 - 4) / 3
        XCTAssertEqual(report.activeFrame(hostWidth: 1000), CGRect(x: 2 + tab, y: 2, width: tab, height: 22))
        XCTAssertEqual(report.activeFrame(hostWidth: 1200)?.width, (380 - 4) / 3)
        var lone = report
        lone.count = 1
        lone.activeIndex = 0
        XCTAssertNil(lone.activeFrame(hostWidth: 1000), "a lone tab needs no platter")
        // Scrolled strip: pixel offsets, clipped to the strip.
        var scrolled = TabCapsule(base: 400, share: 0, y: 13, widthBase: 240, height: 26, activeX: 180, activeWidth: 96)
        XCTAssertEqual(scrolled.activeFrame(hostWidth: 1000), CGRect(x: 180, y: 2, width: 58, height: 22), "clipped to the strip")
        scrolled.activeX = 400
        XCTAssertNil(scrolled.activeFrame(hostWidth: 1000), "scrolled out of view")
    }

    func testSidebarToggleJumpsToTheRememberedLayoutWithoutWaitingForThePage() {
        let layer = TabCapsuleLayer(frame: CGRect(x: 0, y: 0, width: 1200, height: 52))
        let closed = [TabCapsule(base: 400, share: 0.3, y: 13, widthBase: -20, widthShare: 0.5, height: 26, activeIndex: 0, count: 2)]
        let open = [TabCapsule(base: 520, share: 0.3, y: 13, widthBase: -120, widthShare: 0.5, height: 26, activeIndex: 0, count: 2)]
        layer.apply(closed, sidebarOpen: false)
        layer.apply(open, sidebarOpen: true)
        layer.sidebarWillToggle(to: false)
        XCTAssertEqual(layer.strips, closed)
        // Tabs changed since that layout was seen: wait for the page instead.
        layer.apply([TabCapsule(base: 520, share: 0.3, y: 13, widthBase: -120, widthShare: 0.5, height: 26, activeIndex: 2, count: 3)], sidebarOpen: true)
        layer.sidebarWillToggle(to: false)
        XCTAssertEqual(layer.strips.first?.count, 3)
    }
}
