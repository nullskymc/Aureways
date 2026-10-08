import XCTest
@testable import Aureways

/// The menu bar page and the native handler must agree on command names:
/// an unknown name is silently ignored (that is how 退出 broke).
final class MenuBarCommandTests: XCTestCase {
    private func menuBarSource() throws -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WebApp/src/components/MenuBar.tsx")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryPostedCommandIsHandled() throws {
        guard let source = try menuBarSource() else {
            throw XCTSkip("WebApp sources not available")
        }
        let regex = try NSRegularExpression(pattern: #"post\('([A-Za-z.]+)'"#)
        let names = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertFalse(names.isEmpty)
        for name in Set(names) {
            XCTAssertNotNil(WebShellBridge.MenuBarCommand(message: name), "Menu bar page posts '\(name)' but the native handler doesn't know it")
        }
        // Every native command is reachable from the page.
        for command in WebShellBridge.MenuBarCommand.allCases {
            XCTAssertTrue(names.contains(command.rawValue), "Native menu bar command '\(command.rawValue)' is never posted")
        }
    }

    /// The panel follows the page's content height: clamped to the screen,
    /// top edge kept under the status item.
    @MainActor
    func testPanelHeightFollowsContentTopAnchored() {
        XCTAssertEqual(MenuBarLayout.clamp(150, screenHeight: 900), MenuBarLayout.minHeight)
        XCTAssertEqual(MenuBarLayout.clamp(512.3, screenHeight: 900), 513, "whole points, rounded up: never clips")
        XCTAssertEqual(MenuBarLayout.clamp(2000, screenHeight: 900), 888, "fits the screen; the page scrolls the rest")
        XCTAssertEqual(MenuBarLayout.clamp(640, screenHeight: nil), 640)
        let top = MenuBarLayout.frame(for: CGRect(x: 900, y: 400, width: 340, height: 470), height: 560)
        XCTAssertEqual(top, CGRect(x: 900, y: 310, width: 340, height: 560))
        XCTAssertEqual(top.maxY, 870)

        let window = NSWindow(contentRect: CGRect(x: 900, y: 400, width: 340, height: 470), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        MenuBarLayout.resize(window, to: 380, animated: true)
        XCTAssertEqual(window.frame, CGRect(x: 900, y: 490, width: 340, height: 380), "off screen: immediate, top stays at 870")
        MenuBarLayout.resize(window, to: 600, animated: true)
        XCTAssertEqual(window.frame.maxY, 870)
        XCTAssertEqual(window.frame.height, 600)
    }

    func testQuitAliases() {
        XCTAssertEqual(WebShellBridge.MenuBarCommand(message: "quitApp"), .quitApp)
        XCTAssertEqual(WebShellBridge.MenuBarCommand(message: "quit"), .quitApp)
        XCTAssertNil(WebShellBridge.MenuBarCommand(message: "bogus"))
    }

    /// `tell application "Aureways" to quit` (and logout) must really quit; the
    /// Dock's 退出 keeps hiding to the menu bar. Cancelling every quit event is
    /// what made scripted quits fail with -128.
    @MainActor
    func testQuitAppleEventDecision() {
        let aevt = AppActivation.coreEventClass
        let quit = AppActivation.quitEventID
        XCTAssertTrue(AppActivation.shouldQuit(eventClass: aevt, eventID: quit, hasQuitReason: false, senderBundleID: nil), "osascript")
        XCTAssertTrue(AppActivation.shouldQuit(eventClass: aevt, eventID: quit, hasQuitReason: false, senderBundleID: "com.apple.ActivityMonitor"))
        XCTAssertFalse(AppActivation.shouldQuit(eventClass: aevt, eventID: quit, hasQuitReason: false, senderBundleID: "com.apple.dock"))
        XCTAssertTrue(AppActivation.shouldQuit(eventClass: aevt, eventID: quit, hasQuitReason: true, senderBundleID: "com.apple.dock"), "logout / shutdown")
        XCTAssertFalse(AppActivation.shouldQuit(eventClass: aevt, eventID: AEEventID(0x6F64_6F63), hasQuitReason: false, senderBundleID: nil), "odoc is not a quit")
        XCTAssertFalse(AppActivation.isExternalQuitRequest(nil), "menu / ⌘Q path has no Apple Event")
    }
}
