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
    private var composerOverlay: ComposerOverlay?
    private var trafficLights: TrafficLightLayout?

    override var isFlipped: Bool { true }

    init(model: AppModel, role: WebShellBridge.Role = .main) {
        self.role = role
        bridge = WebShellBridge(model: model, role: role)
        let shellWebView = Self.makeWebView(bridge: bridge, navigationGuard: navigationGuard)
        webView = shellWebView
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))

        if role == .main {
            // Content background + Liquid Glass panels; the page is transparent over it.
            glassLayer.frame = bounds
            glassLayer.autoresizingMask = [.width, .height]
            addSubview(glassLayer)
        }

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        if role == .main {
            // Composer overlay: glass + its own transparent web view, above the
            // main page so the glass refracts the transcript scrolling behind it.
            let overlay = ComposerOverlay(model: model, main: bridge)
            composerOverlay = overlay
            addSubview(overlay.glass)
            addSubview(overlay.webView)

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
        bridge.onGlassRects = { [weak self] rects in
            guard let self else { return }
            self.glassLayer.apply(rects.filter { $0.kind != "slot" })
            self.composerOverlay?.slot = rects.first { $0.kind == "slot" }?.frame
        }
        bridge.onFocusComposer = { [weak self] in
            guard let self, let window = self.window else { return }
            if let overlay = self.composerOverlay, overlay.isShown {
                window.makeFirstResponder(overlay.webView)
            } else {
                window.makeFirstResponder(self.webView)
            }
        }
        bridge.onFocusMain = { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.webView)
        }
        navigationGuard.onTerminate = { [weak self] in self?.reload() }
        if role == .main { WebShellBridge.current = bridge }
        reload()
    }

    static func makeWebView(bridge: WebShellBridge, navigationGuard: WebShellNavigationGuard) -> ShellWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebAssetSchemeHandler(), forURLScheme: WebAssetSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakScriptMessageHandler(bridge), name: WebShellBridge.handlerName)
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.isTextInteractionEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        let webView = ShellWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: config)
        // Transparent page background so the native layers show through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = navigationGuard
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
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
        let lights = TrafficLightLayout(window: window)
        lights.onChange = { [weak self] in self?.publishChrome() }
        trafficLights = lights
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trafficLights?.apply()
                    self.publishChrome()
                    if name == NSWindow.didExitFullScreenNotification {
                        // AppKit re-lays out the titlebar after the animation.
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.trafficLights?.apply()
                                self?.publishChrome()
                            }
                        }
                    }
                }
            })
        }
        lights.apply()
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        trafficLights?.apply()
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
    /// When set (composer overlay), only these rects (own coordinates) take
    /// mouse events; everything else falls through to the main page below.
    var hitRegion: [CGRect]?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitRegion {
            guard !isHidden, alphaValue > 0 else { return nil }
            let local = convert(point, from: superview)
            guard hitRegion.contains(where: { $0.contains(local) }) else { return nil }
        }
        return super.hitTest(point)
    }

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

/// Insets the traffic lights inside the floating sidebar glass panel
/// (`glass.ts` insets the panel 8 pt): first button 12 pt from the panel's
/// left edge, vertically centred on a 52 pt header row (the web header
/// follows via `chrome.trafficLights`). The titlebar container is grown to
/// that height so the moved buttons stay inside it and clickable. Re-applied
/// on resize / fullscreen exit / key / appearance changes and whenever AppKit
/// re-lays out the titlebar (frame-change notifications). Fullscreen is left
/// to AppKit.
@MainActor
final class TrafficLightLayout {
    static let headerHeight: CGFloat = 52
    static let leading: CGFloat = 20

    private weak var window: NSWindow?
    private var spacing: CGFloat?
    private var applying = false
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    private var buttons: [NSButton] {
        guard let window else { return [] }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
    }

    private func observe(_ views: [NSView]) {
        guard observers.isEmpty else { return }
        for view in views {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.apply() }
                    }
                }
            })
        }
    }

    func apply() {
        guard let window, !applying, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = buttons
        guard let close = buttons.first, let titlebar = close.superview, let container = titlebar.superview,
              let frameView = container.superview else { return }
        if spacing == nil, buttons.count > 1 {
            spacing = buttons[1].frame.minX - buttons[0].frame.minX
        }
        applying = true
        defer { applying = false }
        var changed = false
        let height = Self.headerHeight
        let containerFrame = NSRect(x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
        if container.frame != containerFrame {
            container.frame = containerFrame
            changed = true
        }
        if titlebar.frame != container.bounds {
            titlebar.frame = container.bounds
            changed = true
        }
        let step = spacing ?? 20
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(
                x: Self.leading + CGFloat(index) * step,
                y: ((height - button.frame.height) / 2).rounded()
            )
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
                changed = true
            }
        }
        observe([container, titlebar, close])
        if changed { onChange?() }
    }
}

/// The composer while a session is open: its own small transparent
/// `WKWebView` (`#composer`) over an `NSGlassEffectView`, both above the main
/// page so the glass refracts the transcript scrolling behind it.
///
/// Placement: the main page reports a `slot` rect (x, width and bottom of the
/// composer's place in the dock); the composer page reports its content
/// height and the card/popup rects (`composerLayout`). Only this overlay's
/// frames are set; nothing feeds back into SwiftUI or the main page layout
/// except the card height, which the main page uses for its bottom inset.
@MainActor
final class ComposerOverlay {
    let bridge: WebShellBridge
    let webView: ShellWebView
    let glass = NSGlassEffectView()
    private let navigationGuard = WebShellNavigationGuard()
    private weak var main: WebShellBridge?
    private var layout: Layout?
    private var lastCardHeight: CGFloat = -1

    struct Layout {
        var height: CGFloat
        var card: CGRect      // x, w, h; y = distance from the overlay's bottom
        var radius: CGFloat
        var popup: CGRect?
    }

    var slot: CGRect? {
        didSet { if slot != oldValue { place() } }
    }

    private(set) var isShown = false

    init(model: AppModel, main: WebShellBridge) {
        self.main = main
        bridge = WebShellBridge(model: model, role: .composer)
        webView = WebShellHostView.makeWebView(bridge: bridge, navigationGuard: navigationGuard)
        webView.bridge = bridge
        // Transparent rather than hidden while unused: hidden web views stop
        // rendering, so showing one again paints a beat late.
        webView.frame = CGRect(x: 0, y: 0, width: 760, height: 120)
        webView.alphaValue = 0
        webView.hitRegion = []
        // Between messages (live resize), stay bottom-anchored and roughly centred.
        webView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        glass.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        glass.style = .regular
        glass.cornerRadius = 22
        glass.contentView = NSView()
        glass.isHidden = true
        bridge.webView = webView
        bridge.hostView = webView
        main.composerPeer = bridge
        bridge.onComposerLayout = { [weak self] body in self?.receive(body) }
        navigationGuard.onTerminate = { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        bridge.webWillReload()
        var url = WebAssetSchemeHandler.indexURL
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.fragment = "composer"
            url = components.url ?? url
        }
        webView.load(URLRequest(url: url))
    }

    private func receive(_ body: [String: Any]) {
        func rect(_ any: Any?) -> CGRect? {
            guard let dict = any as? [String: Any] else { return nil }
            func number(_ key: String) -> CGFloat { CGFloat((dict[key] as? NSNumber)?.doubleValue ?? 0) }
            return CGRect(x: number("x"), y: number("b"), width: number("w"), height: number("h"))
        }
        let height = CGFloat((body["h"] as? NSNumber)?.doubleValue ?? 0)
        guard height > 0, let card = rect(body["card"]) else {
            layout = nil
            place()
            return
        }
        let radius = CGFloat(((body["card"] as? [String: Any])?["r"] as? NSNumber)?.doubleValue ?? 22)
        layout = Layout(height: height.rounded(.up), card: card, radius: radius, popup: rect(body["popup"]))
        place()
    }

    private func place() {
        guard let slot, let layout, slot.width > 0 else {
            setShown(false)
            return
        }
        let bottom = slot.maxY
        let frame = CGRect(x: slot.minX, y: bottom - layout.height, width: slot.width, height: layout.height).integral
        if webView.frame != frame { webView.frame = frame }
        // Overlay-local rects (web view is flipped: y from its top).
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: frame.height - r.minY - r.height, width: r.width, height: r.height)
        }
        let card = local(layout.card)
        webView.hitRegion = [card] + (layout.popup.map { [local($0)] } ?? [])
        let glassFrame = card.offsetBy(dx: frame.minX, dy: frame.minY)
        if glass.frame != glassFrame { glass.frame = glassFrame }
        if glass.cornerRadius != layout.radius { glass.cornerRadius = layout.radius }
        if abs(layout.card.height - lastCardHeight) > 0.5 {
            lastCardHeight = layout.card.height
            main?.sendCommand("composerHeight", ["h": layout.card.height])
        }
        setShown(true)
    }

    private func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        webView.alphaValue = shown ? 1 : 0
        if !shown { webView.hitRegion = [] }
        glass.isHidden = !shown
        if !shown, let window = webView.window, window.firstResponder === webView {
            window.makeFirstResponder(main?.webView)
        }
    }
}
