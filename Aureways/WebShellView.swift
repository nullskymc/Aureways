import AppKit
import SwiftUI
import WebKit

/// The main window is a thin native shell around one `WKWebView`.
/// See docs/web-shell.md. The old SwiftUI `NavigationSplitView` root is only
/// reachable through this defaults flag (it can hit the AppKit
/// "more Update Constraints in Window passes than there are views" crash).
enum WebShellFlag {
    static let legacyKey = "useLegacyNativeUI"
    static var useLegacy: Bool { UserDefaults.standard.bool(forKey: legacyKey) }
}

/// SwiftUI side of the shell: no layout of its own, just environment hooks.
struct WebShellRoot: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        WebShellRepresentable(model: model)
            .ignoresSafeArea()
            .onAppear {
                AppActivation.openMainWindow = { openWindow(id: AppActivation.mainWindowID) }
                WebShellBridge.openSettingsAction = {
                    AppActivation.prepareForSettings()
                    openSettings()
                }
                AppActivation.flushPendingOpens()
            }
            .onReceive(NotificationCenter.default.publisher(for: .aurewaysRevealMainWindow)) { _ in
                AppActivation.revealMainWindow()
            }
    }
}

struct WebShellRepresentable: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> WebShellHostView {
        WebShellHostView(model: model)
    }

    func updateNSView(_ nsView: WebShellHostView, context: Context) {}

    /// Always take exactly what SwiftUI proposes; never feed a size back.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WebShellHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 820)
    }
}

/// Window content: material backdrop, transparent web view, titlebar drag strip.
/// Frames only (autoresizing masks), no Auto Layout constraints.
@MainActor
final class WebShellHostView: NSView {
    static let titlebarHeight: CGFloat = 46

    let bridge: WebShellBridge
    let webView: WKWebView
    private let backdrop = NSVisualEffectView()
    private let dragStrip = TitlebarDragStrip()
    private let navigationGuard = WebShellNavigationGuard()
    private var windowObservers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    init(model: AppModel) {
        bridge = WebShellBridge(model: model)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebAssetSchemeHandler(), forURLScheme: WebAssetSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakScriptMessageHandler(bridge), name: WebShellBridge.handlerName)
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: config)
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))

        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        // Transparent page background so the material shows through the sidebar.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = navigationGuard
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        dragStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.titlebarHeight)
        dragStrip.autoresizingMask = [.width, .maxYMargin]
        addSubview(dragStrip)

        bridge.webView = webView
        bridge.hostView = self
        bridge.onDragRegions = { [weak self] rects, height in
            guard let self else { return }
            self.dragStrip.exclusions = rects
            if let height, height > 0, abs(self.dragStrip.frame.height - height) > 0.5 {
                self.dragStrip.frame = NSRect(x: 0, y: 0, width: self.bounds.width, height: height)
            }
        }
        bridge.onAppearance = { [weak self] value in self?.applyAppearance(value) }
        navigationGuard.onTerminate = { [weak self] in self?.reload() }
        WebShellBridge.current = bridge
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        bridge.webWillReload()
        webView.load(URLRequest(url: WebAssetSchemeHandler.indexURL))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { return }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if window.toolbar != nil { window.toolbar = nil }
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        applyAppearance(bridge.model.appearance)
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishChrome() }
            })
        }
        publishChrome()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self.webView)
            }
        }
    }

    /// Tell the web app where the traffic lights are so its header can clear them.
    func publishChrome() {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var union = CGRect.null
        for type in buttons {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            union = union.union(button.convert(button.bounds, to: self))
        }
        let fullscreen = window.styleMask.contains(.fullScreen)
        bridge.updateChrome(WebShellBridge.Chrome(
            trafficLights: union.isNull ? .zero : union,
            fullscreen: fullscreen,
            titlebarHeight: Self.titlebarHeight
        ))
    }

    private func applyAppearance(_ value: String) {
        let appearance: NSAppearance?
        switch value {
        case "dark": appearance = NSAppearance(named: .darkAqua)
        case "light": appearance = NSAppearance(named: .aqua)
        default: appearance = nil
        }
        // SwiftUI's Window scene may reassign the window's appearance, so pin
        // it on our own view tree too (vibrancy + WKWebView follow the view).
        if window?.appearance != appearance { window?.appearance = appearance }
        if self.appearance != appearance { self.appearance = appearance }
    }
}

/// `-webkit-app-region` does not exist in WKWebView. This strip sits over the
/// header and drags the window; the web app reports rects of its header
/// controls so clicks there fall through to the page.
final class TitlebarDragStrip: NSView {
    var exclusions: [CGRect] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if exclusions.contains(where: { $0.contains(local) }) { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

/// `WKUserContentController` retains its handlers; keep the bridge weak.
@MainActor
final class WeakScriptMessageHandler: NSObject, @preconcurrency WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Only the bundled app loads in-page; links go native.
@MainActor
final class WebShellNavigationGuard: NSObject, @preconcurrency WKNavigationDelegate {
    var onTerminate: (() -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == WebAssetSchemeHandler.scheme { return .allow }
        if navigationAction.navigationType == .linkActivated {
            WebAssetSchemeHandler.openExternally(url.absoluteString)
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onTerminate?()
    }
}
