import AppKit
import WebKit

/// Shared WebKit plumbing for the web transcript prototype: one configuration,
/// a custom URL scheme serving the bundled renderer, and a small pool of
/// pre-loaded web views so virtualized rows can attach instantly.
@MainActor
final class WebTranscriptRuntime: NSObject {
    static let shared = WebTranscriptRuntime()

    static let scheme = "aureways-web"
    static let messageHandlerName = "aureways"
    private static let indexURL = URL(string: "\(scheme)://app/index.html")!

    /// `Aureways.app/Contents/Resources/WebTranscriptBundle`, built from
    /// `WebTranscript/` (see its README). nil if the resource is missing.
    let bundleRoot: URL?

    private lazy var configuration: WKWebViewConfiguration = makeConfiguration()
    private let schemeHandler: WebTranscriptSchemeHandler
    private let messageRouter = WebTranscriptMessageRouter()
    private let navigationGuard = WebTranscriptNavigationGuard()

    /// Loaded, unassigned views ready for a new message.
    private var idle: [TranscriptWebView] = []
    /// Detached views that still hold a rendered message (LRU, newest last).
    private var parked: [(id: String, view: TranscriptWebView)] = []
    private let idleTarget = 2
    private let parkedLimit = 24

    private var heights: [String: CGFloat] = [:]

    override private init() {
        let root = Bundle.main.url(forResource: "WebTranscriptBundle", withExtension: nil)
        bundleRoot = root
        schemeHandler = WebTranscriptSchemeHandler(root: root)
        super.init()
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(messageRouter, name: Self.messageHandlerName)
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return config
    }

    // MARK: Pool

    func checkout(messageID: String) -> TranscriptWebView {
        defer { scheduleWarmup() }
        if let index = parked.lastIndex(where: { $0.id == messageID }) {
            return parked.remove(at: index).view
        }
        let view = idle.popLast() ?? makeView()
        view.assign(messageID: messageID)
        return view
    }

    func checkin(_ view: TranscriptWebView) {
        view.removeFromSuperview()
        guard let id = view.messageID else {
            if idle.count < idleTarget { idle.append(view) }
            return
        }
        parked.removeAll { $0.view === view }
        parked.append((id, view))
        while parked.count > parkedLimit {
            let evicted = parked.removeFirst().view
            if idle.count < idleTarget {
                idle.append(evicted) // reassigned (and cleared) on next checkout
            }
        }
    }

    private var warmupScheduled = false
    private func scheduleWarmup() {
        guard !warmupScheduled, idle.count < idleTarget else { return }
        warmupScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warmupScheduled = false
                while self.idle.count < self.idleTarget {
                    self.idle.append(self.makeView())
                }
            }
        }
    }

    private func makeView() -> TranscriptWebView {
        let view = TranscriptWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 40), configuration: configuration)
        view.navigationDelegate = navigationGuard
        load(view)
        return view
    }

    func load(_ view: TranscriptWebView) {
        view.load(URLRequest(url: Self.indexURL))
    }

    // MARK: Height cache (so recycled rows start at their last measured size)

    func cachedHeight(for messageID: String) -> CGFloat? { heights[messageID] }

    func storeHeight(_ height: CGFloat, for messageID: String) {
        if heights.count > 2000 { heights.removeAll(keepingCapacity: true) }
        heights[messageID] = height
    }

    // MARK: Links

    static func openExternally(_ href: String) {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = (trimmed as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return }
        guard ["http", "https", "mailto", "file"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Script messages

@MainActor
private final class WebTranscriptMessageRouter: NSObject, @preconcurrency WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        (message.webView as? TranscriptWebView)?.receive(message.body)
    }
}

// MARK: - Navigation: only our bundle loads in-page; everything else goes native

@MainActor
private final class WebTranscriptNavigationGuard: NSObject, @preconcurrency WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == WebTranscriptRuntime.scheme { return .allow }
        if navigationAction.navigationType == .linkActivated {
            WebTranscriptRuntime.openExternally(url.absoluteString)
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        (webView as? TranscriptWebView)?.contentProcessDidTerminate()
    }
}

// MARK: - aureways-web:// scheme

/// Serves files from the bundled renderer. A custom scheme (not file://) so the
/// ES-module entry and its lazy Shiki chunks load same-origin; no network.
@MainActor
final class WebTranscriptSchemeHandler: NSObject, @preconcurrency WKURLSchemeHandler {
    private let root: URL?

    init(root: URL?) {
        self.root = root?.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": Self.mimeType(for: file.pathExtension),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "\(WebTranscriptRuntime.scheme)://app",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
