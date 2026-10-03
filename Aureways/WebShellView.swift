import AppKit
import SwiftUI
import WebKit

/// The main window is a thin native shell around one `WKWebView`
/// (docs/web-shell.md).
///
/// SwiftUI side of the shell: no layout of its own, just environment hooks.
struct WebShellRoot: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WebShellRepresentable(model: model)
            .ignoresSafeArea()
            .onAppear {
                AppActivation.openMainWindow = { openWindow(id: AppActivation.mainWindowID) }
                AppActivation.flushPendingOpens()
            }
            .onReceive(NotificationCenter.default.publisher(for: .aurewaysRevealMainWindow)) { _ in
                AppActivation.revealMainWindow()
            }
    }
}

/// Menu bar extra content: same bundle at `#menubar`, fixed size.
struct MenuBarWebView: NSViewRepresentable {
    let model: AppModel
    static let size = CGSize(width: 340, height: 470)

    func makeNSView(context: Context) -> WebShellHostView {
        WebShellHostView(model: model, role: .menuBar)
    }

    func updateNSView(_ nsView: WebShellHostView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WebShellHostView, context: Context) -> CGSize? {
        Self.size
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

/// Window content: content background + Liquid Glass layer, transparent web view, titlebar drag strip.
/// Frames only (autoresizing masks), no Auto Layout constraints.
@MainActor
final class WebShellHostView: NSView {
    static let titlebarHeight: CGFloat = 46

    let bridge: WebShellBridge
    let webView: WKWebView
    let role: WebShellBridge.Role
    private let glassLayer = GlassLayerView()
    private let dragStrip = TitlebarDragStrip()
    private let navigationGuard = WebShellNavigationGuard()
    private var windowObservers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    init(model: AppModel, role: WebShellBridge.Role = .main) {
        self.role = role
        bridge = WebShellBridge(model: model, role: role)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebAssetSchemeHandler(), forURLScheme: WebAssetSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakScriptMessageHandler(bridge), name: WebShellBridge.handlerName)
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        let shellWebView = ShellWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: config)
        webView = shellWebView
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))

        if role == .main {
            // Content background + Liquid Glass panels; the page is transparent over it.
            glassLayer.frame = bounds
            glassLayer.autoresizingMask = [.width, .height]
            addSubview(glassLayer)
        }

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

        if role == .main {
            dragStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.titlebarHeight)
            dragStrip.autoresizingMask = [.width, .maxYMargin]
            addSubview(dragStrip)
        }

        bridge.webView = webView
        bridge.hostView = self
        shellWebView.bridge = bridge
        bridge.onDragRegions = { [weak self] rects, height in
            guard let self else { return }
            self.dragStrip.exclusions = rects
            if let height, height > 0, abs(self.dragStrip.frame.height - height) > 0.5 {
                self.dragStrip.frame = NSRect(x: 0, y: 0, width: self.bounds.width, height: height)
            }
        }
        bridge.onAppearance = { [weak self] value in self?.applyAppearance(value) }
        bridge.onGlassRects = { [weak self] rects in self?.glassLayer.apply(rects) }
        navigationGuard.onTerminate = { [weak self] in self?.reload() }
        if role == .main { WebShellBridge.current = bridge }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        bridge.webWillReload()
        var url = WebAssetSchemeHandler.indexURL
        if role == .menuBar, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.fragment = "menubar"
            url = components.url ?? url
        }
        webView.load(URLRequest(url: url))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { return }
        guard role == .main else {
            applyAppearance(bridge.model.appearance)
            return
        }
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

/// Files dragged in from Finder become composer attachments natively (the
/// page only sees sandboxed File objects without paths). Other drags (text
/// into the composer) go to WebKit as usual.
final class ShellWebView: WKWebView {
    weak var bridge: WebShellBridge?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return super.draggingEntered(sender) }
        bridge?.sendCommand("dropHover")
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, !fileURLs(sender).isEmpty {
            bridge?.sendCommand("dropEnd")
            return
        }
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        bridge?.sendCommand("dropEnd")
        bridge?.pendingAttachments.append(contentsOf: ComposerAttachment.fromFileURLs(urls))
        bridge?.sendCommand("focusComposer")
        return true
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
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
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
final class WebShellNavigationGuard: NSObject, WKNavigationDelegate {
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

/// Native layer under the transparent web view: the main content background
/// (matches `--main-bg` in styles.css) and `NSGlassEffectView`s at rects the
/// page reports for elements marked `data-glass` (sidebar panel, header
/// control groups, composer). Frames only; it never affects web or SwiftUI
/// layout, and it never takes mouse events.
@MainActor
final class GlassLayerView: NSView {
    struct Panel: Equatable {
        var kind: String
        var frame: CGRect
        var radius: CGFloat
    }

    /// `--main-bg`: light #fdfdfd, dark #161618.
    static let contentBackground = NSColor(name: "AurewaysContentBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x18 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xfd / 255.0, green: 0xfd / 255.0, blue: 0xfd / 255.0, alpha: 1)
    }

    private let container = NSGlassEffectContainerView()
    private let content = FlippedView()
    private var views: [NSGlassEffectView] = []
    private var panels: [Panel] = []

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.contentView = content
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = Self.contentBackground.resolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ next: [Panel]) {
        guard next != panels else { return }
        panels = next
        while views.count < next.count {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = NSView()
            content.addSubview(glass)
            views.append(glass)
        }
        while views.count > next.count {
            views.removeLast().removeFromSuperview()
        }
        for (glass, panel) in zip(views, next) {
            if glass.frame != panel.frame { glass.frame = panel.frame }
            if glass.cornerRadius != panel.radius { glass.cornerRadius = panel.radius }
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSColor {
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var color = cgColor
        appearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}
