import AppKit
import WebKit
import XCTest
@testable import Aureways

@MainActor
final class TitlebarTests: XCTestCase {
    func testTrafficLightsAndBridgeUseOneHeight() {
        XCTAssertEqual(WebShellHostView.titlebarHeight, TrafficLightLayout.headerHeight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.titlebarAppearsTransparent = true
        let lights = TrafficLightLayout(window: window)
        lights.apply()
        let close = window.standardWindowButton(.closeButton)!
        XCTAssertEqual(close.superview!.frame.height, WebShellHostView.titlebarHeight)
        XCTAssertEqual(close.frame.midY, WebShellHostView.titlebarHeight / 2, accuracy: 0.5)
    }

    func testNativeBackdropDoesNotEatTabClicks() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let backdrop = TitlebarBackdropView(frame: NSRect(x: 0, y: 0, width: 900, height: 52))
        let strip = TitlebarDragStrip(frame: backdrop.frame)
        parent.addSubview(backdrop)
        parent.addSubview(strip)
        strip.exclusions = [CGRect(x: 300, y: 10, width: 180, height: 30)]
        XCTAssertNil(backdrop.hitTest(NSPoint(x: 320, y: 20)))
        XCTAssertNil(strip.hitTest(NSPoint(x: 320, y: 20)))
        XCTAssertTrue(strip.hitTest(NSPoint(x: 600, y: 20)) === strip)
        XCTAssertNil(strip.hitTest(NSPoint(x: 600, y: 60)))
    }

    func testSidebarChromeJoinsTitlebarWithoutInsetOrGlassBevel() throws {
        let layer = GlassLayerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let frame = NSRect(x: 0, y: 0, width: 272, height: 600)
        layer.apply([GlassLayerView.Panel(kind: "sidebar", frame: frame, radius: 0)])
        let sidebar = try XCTUnwrap(layer.subviews.compactMap { $0 as? TitlebarBackdropView }.first)
        let titlebar = TitlebarBackdropView(frame: NSRect(x: 0, y: 0, width: 1000, height: 52))
        XCTAssertFalse(sidebar.isHidden)
        XCTAssertEqual(sidebar.frame, frame)
        XCTAssertNil(sidebar.hitTest(NSPoint(x: 20, y: 100)))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            sidebar.appearance = NSAppearance(named: name)
            titlebar.appearance = NSAppearance(named: name)
            sidebar.updateLayer()
            titlebar.updateLayer()
            XCTAssertEqual(sidebar.layer?.backgroundColor, titlebar.layer?.backgroundColor)
        }
        layer.setFrameSize(NSSize(width: 1200, height: 700))
        XCTAssertEqual(sidebar.frame, NSRect(x: 0, y: 0, width: 272, height: 700))
        layer.apply([])
        XCTAssertTrue(sidebar.isHidden)
    }

    func testWKWebViewKeepsContentBelowNativeTitlebar() async throws {
        let cssURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WebApp/src/styles.css")
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        // Use the same full-size, transparent NSWindow/WKWebView layering as
        // the Swift app rather than a standalone browser viewport.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.close() }
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = host
        let backdrop = TitlebarBackdropView(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 52))
        backdrop.autoresizingMask = [.width, .maxYMargin]
        host.addSubview(backdrop)
        let web = WKWebView(frame: host.bounds)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        host.addSubview(web)
        let lights = TrafficLightLayout(window: window)
        lights.apply()
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertEqual(close.convert(close.bounds, to: host).midY, 26, accuracy: 0.5)
        let loaded = expectation(description: "WebKit loaded native-titlebar fixture")
        let delegate = LoadDelegate(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString("""
        <html class="glass"><head><style>\(css)</style></head><body><div id="app">
        <div class="app native-titlebar" style="--head-h:52px;--sidebar-w:220px">
        <aside class="sidebar"><header class="sidebar-head"><button>Sidebar</button></header></aside>
        <main class="main"><div class="editors"><section class="column chat-column" style="flex:1">
        <header class="main-head tab-strip"><button id="tab">Chat</button></header>
        <div class="chat-panel"><div class="transcript"><div class="vscroll"><div style="height:2000px">content</div></div></div></div>
        </section><section class="column" style="flex:1">
        <header class="main-head tab-strip"><button>File</button></header>
        <div class="insp-panel">File content</div>
        </section></div></main></div></div></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        for height in [52, 44] {
            // Normal window and the compact fullscreen header, including a
            // narrow resize while the sidebar and both columns are present.
            host.setFrameSize(NSSize(width: height == 52 ? 1000 : 760, height: 600))
            let result = try await web.evaluateJavaScript("""
            (() => {
              document.querySelector('.app').style.setProperty('--head-h', '\(height)px');
              const header = document.querySelector('.chat-column header');
              const chat = document.querySelector('.chat-panel');
              const headers = [...document.querySelectorAll('header')];
              document.querySelector('.vscroll').scrollTop = 300;
              return { heights: headers.map(h => h.getBoundingClientRect().height),
                top: chat.getBoundingClientRect().top,
                backgrounds: headers.map(h => getComputedStyle(h).backgroundColor),
                overflow: getComputedStyle(chat).overflow,
                sidebarLeft: document.querySelector('.sidebar').getBoundingClientRect().left,
                sidebarPadding: getComputedStyle(document.querySelector('.sidebar')).padding,
                hit: document.elementFromPoint(header.getBoundingClientRect().left + 20, \(height) / 2).closest('header') !== null };
            })()
            """) as! [String: Any]
            XCTAssertEqual(result["heights"] as? [Double], Array(repeating: Double(height), count: 3))
            XCTAssertEqual(result["top"] as? Double, Double(height))
            XCTAssertEqual(result["backgrounds"] as? [String], Array(repeating: "rgba(0, 0, 0, 0)", count: 3))
            XCTAssertEqual(result["overflow"] as? String, "hidden")
            XCTAssertEqual(result["sidebarLeft"] as? Double, 0)
            XCTAssertEqual(result["sidebarPadding"] as? String, "0px")
            XCTAssertEqual(result["hit"] as? Bool, true)
            XCTAssertEqual(backdrop.frame.minY, 0)
            XCTAssertEqual(backdrop.frame.width, host.bounds.width)
        }
        let collapsed = try await web.evaluateJavaScript("""
        (() => {
          const side = document.querySelectorAll('.column')[1];
          const chat = document.querySelector('.chat-column');
          const before = chat.getBoundingClientRect().width;
          side.hidden = true;
          const result = { hiddenWidth: side.getBoundingClientRect().width,
            fillsMain: chat.getBoundingClientRect().right === document.querySelector('.main').getBoundingClientRect().right };
          side.hidden = false;
          result.restored = chat.getBoundingClientRect().width === before;
          return result;
        })()
        """) as! [String: Any]
        XCTAssertEqual(collapsed["hiddenWidth"] as? Double, 0)
        XCTAssertEqual(collapsed["fillsMain"] as? Bool, true)
        XCTAssertEqual(collapsed["restored"] as? Bool, true)
        _ = delegate // Retain until navigation and evaluation have finished.
    }
}

@MainActor
private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

@MainActor
private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}
