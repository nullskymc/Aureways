import AppKit
import WebKit

/// Serves the bundled web app (`Aureways.app/Contents/Resources/WebAppBundle`,
/// built from `WebApp/`) under `aureways-web://app/`. A custom scheme rather
/// than file:// so ES modules and lazy chunks load same-origin, with no network.
@MainActor
final class WebAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "aureways-web"
    static let indexURL = URL(string: "\(scheme)://app/index.html")!

    /// nil if the resource folder is missing from the bundle.
    static var bundleRoot: URL? {
        Bundle.main.url(forResource: "WebAppBundle", withExtension: nil)
    }

    private let root: URL?

    init(root: URL? = WebAssetSchemeHandler.bundleRoot) {
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
            "Access-Control-Allow-Origin": "\(Self.scheme)://app",
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

    static func mimeType(for ext: String) -> String {
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

    /// Links clicked in the web app open natively; only safe schemes and paths.
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
