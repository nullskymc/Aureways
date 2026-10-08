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
