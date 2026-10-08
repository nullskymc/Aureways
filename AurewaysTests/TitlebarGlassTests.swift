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

    func testNewChatIsANativeCircleGroupedWithTheSidebarToggle() {
        let side = TitlebarMetrics.sidebarFrame(lights: lights, fullscreen: false, headerHeight: 52)
        XCTAssertEqual(TitlebarMetrics.newChatFrame(sidebar: side), CGRect(x: 122, y: 11, width: 30, height: 30))
        XCTAssertEqual(TitlebarMetrics.insets(sidebar: side, width: 1200).newChat, 160, "page content clears both circles")
        let buttons = TitlebarButtons(frame: CGRect(x: 0, y: 0, width: 1200, height: 52))
        buttons.layout(lights: lights, fullscreen: false, headerHeight: 52)
        XCTAssertFalse(buttons.isNewChatVisible, "sidebar open: New chat is the sidebar's row")
        buttons.setNewChatVisible(true)
        XCTAssertTrue(buttons.isNewChatVisible)
        XCTAssertEqual(buttons.newChatFrame, CGRect(x: 122, y: 11, width: 30, height: 30))
        XCTAssertTrue(buttons.newChatGlass.superview === buttons.sidebarGlass.superview, "same glass container as the sidebar toggle")
        // Full screen: follows the sidebar circle natively.
        buttons.layout(lights: lights, fullscreen: true, headerHeight: 44)
        XCTAssertEqual(buttons.newChatFrame, CGRect(x: 50, y: 7, width: 30, height: 30))
        buttons.setNewChatVisible(false)
        XCTAssertFalse(buttons.isNewChatVisible)
    }

    func testSplitRightCircleFollowsItsStripThroughResize() {
        let strip = TabCapsule(base: 650 - 0.375 * 1000, share: 0.375, y: 13, widthBase: 330 - 0.25 * 1000, widthShare: 0.25,
                               height: 26, activeIndex: 1, count: 3, split: .init(offset: 6, size: 26, enabled: true))
        XCTAssertEqual(strip.splitFrame(hostWidth: 1000), CGRect(x: 986, y: 13, width: 26, height: 26))
        XCTAssertEqual(strip.splitFrame(hostWidth: 1200), CGRect(x: 1111, y: 13, width: 26, height: 26), "same report, wider window")
        let layer = TabCapsuleLayer(frame: CGRect(x: 0, y: 0, width: 1000, height: 52))
        var plain = strip
        plain.split = nil
        layer.apply([strip, plain], sidebarOpen: true)
        XCTAssertEqual(layer.splitFrames, [CGRect(x: 986, y: 13, width: 26, height: 26), nil])
        layer.setFrameSize(NSSize(width: 1200, height: 52))
        XCTAssertEqual(layer.splitFrames.first ?? nil, CGRect(x: 1111, y: 13, width: 26, height: 26), "live resize, no page report")
        XCTAssertNil(layer.hitTest(NSPoint(x: 1120, y: 26)), "clicks go to the page's transparent button")
        var disabled = strip
        disabled.split?.enabled = false
        XCTAssertFalse(disabled.sameShape(as: strip), "a disabled split is a real change")
    }

    func testClosedWorkbenchLeavesOnlyTheInspectorToggle() {
        XCTAssertEqual(TitlebarMetrics.rightFrame(width: 1200, centerY: 26, compact: true), CGRect(x: 1158, y: 11, width: 30, height: 30))
        let compact = TitlebarMetrics.rightButtonFrames(width: 30, compact: true)
        XCTAssertEqual(compact.inspector.midX, 15, "inspector toggle centred in the circle")
        let full = TitlebarMetrics.rightButtonFrames(width: 68, compact: false)
        XCTAssertEqual(full.fileTree, CGRect(x: 2, y: 0, width: 32, height: 30))
        XCTAssertEqual(full.inspector, CGRect(x: 34, y: 0, width: 32, height: 30))

        let buttons = TitlebarButtons(frame: CGRect(x: 0, y: 0, width: 1200, height: 52))
        buttons.layout(lights: lights, fullscreen: false, headerHeight: 52)
        buttons.setRightVisible(true, add: false, compact: true)
        XCTAssertEqual(buttons.rightGlass.frame, CGRect(x: 1158, y: 11, width: 30, height: 30))
        XCTAssertFalse(buttons.isAddVisible)
        XCTAssertFalse(buttons.isFileTreeVisible)
        // Workbench opens: "+" and the file tree toggle come back, laid out natively.
        buttons.setRightVisible(true, add: true, compact: false)
        XCTAssertEqual(buttons.rightGlass.frame, CGRect(x: 1120, y: 11, width: 68, height: 30))
        XCTAssertEqual(buttons.addButtonFrame, CGRect(x: 1082, y: 11, width: 30, height: 30))
        XCTAssertTrue(buttons.isAddVisible)
        XCTAssertTrue(buttons.isFileTreeVisible)
        // Live resize: the group follows the right edge without a page message.
        buttons.setFrameSize(NSSize(width: 1000, height: 52))
        XCTAssertEqual(buttons.rightGlass.frame.maxX, 988)
        XCTAssertEqual(buttons.addButtonFrame.maxX, 1000 - 12 - 68 - 8)
        // Documents: no toggles, "+" alone at the edge.
        buttons.setRightVisible(false, add: true)
        XCTAssertEqual(buttons.addButtonFrame, CGRect(x: 958, y: 11, width: 30, height: 30))
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
