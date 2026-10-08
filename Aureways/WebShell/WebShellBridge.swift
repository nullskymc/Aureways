import AppKit
import Observation
import QuartzCore
import WebKit
import UserNotifications

/// Composer draft attachments, shared by the main and composer-overlay pages.
@Observable
@MainActor
final class WebComposerDraft {
    static let shared = WebComposerDraft()
    var attachments: [ComposerAttachment] = []
}

/// Swift <-> JS bridge for the web shell (protocol: docs/web-shell.md).
///
/// Observes `AppModel` / the selected `ChatSession` with
/// `withObservationTracking`; any change schedules a flush, throttled to
/// ~45 Hz. A flush sends the app snapshot only when its JSON changed, and the
/// selected transcript as incremental ops (suffix appends for streaming text).
@MainActor
final class WebShellBridge: NSObject {
    static let handlerName = "aureways"
    static weak var current: WebShellBridge?

    struct Chrome: Equatable {
        var trafficLights: CGRect
        var fullscreen: Bool
        var titlebarHeight: CGFloat
    }

    enum Role { case main, menuBar, composer }

    let model: AppModel
    let role: Role
    weak var webView: WKWebView?
    weak var hostView: NSView?
    var onDragRegions: (([CGRect], CGFloat?) -> Void)?
    var onAppearance: ((String) -> Void)?
    var onGlassRects: (([GlassLayerView.Panel]) -> Void)?

    var isReady = false
    private var flushPending = false
    private var lastFlushTime: CFTimeInterval = 0
    private static let minFlushInterval: CFTimeInterval = 1.0 / 45.0
    private var lastStateJSON = ""
    private var lastAppearance: String?
    var chrome = Chrome(trafficLights: .zero, fullscreen: false, titlebarHeight: WebShellHostView.titlebarHeight)

    private var transcriptSessionID: UUID?
    private var sentOrder: [UUID] = []
    private var sentItems: [UUID: TranscriptItem] = [:]
    private var sentRuns: [UUID: ActivityRun] = [:]

    /// Shared by the main page and the composer overlay page (both bridges
    /// observe it through `encodeState`).
    var pendingAttachments: [ComposerAttachment] {
        get { WebComposerDraft.shared.attachments }
        set { WebComposerDraft.shared.attachments = newValue }
    }

    /// Main bridge only: the composer overlay's bridge (composer page) and
    /// host hooks for focus routing / overlay layout.
    weak var composerPeer: WebShellBridge?
    var onFocusComposer: (() -> Void)?
    var onFocusMain: (() -> Void)?
    var onComposerLayout: (([String: Any]) -> Void)?
    /// The page (re)loaded and signalled `ready` (after queued commands).
    var onReady: (() -> Void)?

    let terminals = WebTerminalService()
    var markdownDefaultCache = false
    let notifier = AttentionNotifier()
    static let uiPrefsKey = "webShellUIPrefs"
    var uiPrefs: [String: Any] = UserDefaults.standard.dictionary(forKey: WebShellBridge.uiPrefsKey) ?? [:]

    init(model: AppModel, role: Role = .main) {
        self.model = model
        self.role = role
        super.init()
        guard role == .main else { return }
        terminals.onEmit = { [weak self] payload in self?.post(payload) }
        notifier.onActivate = { [weak self] sessionID in
            guard let self, let session = self.model.sessions.first(where: { $0.id == sessionID }) else { return }
            AppActivation.revealMainWindow()
            self.model.select(session)
        }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    #if DEBUG
    /// Test hooks for driving the shell from a terminal (Debug builds only):
    /// `ai.aureways.debug.eval` evaluates its string object as JS and writes the
    /// result to /tmp/aureways_eval.out; `ai.aureways.debug.frame` takes
    /// "x,y,w,h" (screen coordinates) and sets the window frame.
    private static var debugMenuBarPanel: NSPanel?

    static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// The `#menubar` host inside the real MenuBarExtra window (not the stand-in).
    static func realMenuBarHost() -> WebShellHostView? {
        for window in NSApp.windows where window !== debugMenuBarPanel {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            if let host = firstSubview(of: WebShellHostView.self, in: root), host.role == .menuBar { return host }
        }
        return nil
    }

    private func installDebugHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("ai.aureways.debug.eval"), object: nil, queue: .main) { [weak self] note in
            guard var js = note.object as? String else { return }
            MainActor.assumeIsolated {
                // "@composer <js>" targets the composer overlay page.
                var target = self?.webView
                if js.hasPrefix("@composer ") {
                    js.removeFirst("@composer ".count)
                    target = self?.composerPeer?.webView
                }
                if js.hasPrefix("@menubar ") {
                    js.removeFirst("@menubar ".count)
                    target = (Self.debugMenuBarPanel?.contentView as? WebShellHostView)?.webView
                }
                if js.hasPrefix("@realmenubar ") {
                    js.removeFirst("@realmenubar ".count)
                    target = Self.realMenuBarHost()?.webView
                }
                target?.evaluateJavaScript(js) { result, error in
                    let text = error.map { "error: \($0)" } ?? String(describing: result ?? "nil")
                    try? text.write(toFile: "/tmp/aureways_eval.out", atomically: true, encoding: .utf8)
                }
            }
        }
        // "n" / "f" / …: a synthetic ⌘-key event through NSApp.sendEvent, so the
        // native menu's key equivalents are exercised like a real key press.
        center.addObserver(forName: Notification.Name("ai.aureways.debug.key"), object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String, let char = key.first else { return }
            MainActor.assumeIsolated {
                let codes: [Character: UInt16] = ["n": 45, "f": 3, "o": 31, ",": 43, "i": 34]
                let window = self?.hostView?.window
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: key.count > 1 ? [.command, .option] : .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                    context: nil, characters: String(char), charactersIgnoringModifiers: String(char),
                    isARepeat: false, keyCode: codes[char] ?? 0
                ) else { return }
                NSApp.sendEvent(event)
                try? "sent \(key)".write(toFile: "/tmp/aureways_eval.out", atomically: true, encoding: .utf8)
            }
        }
        // "x,y" (window points, top-left origin) → class of the view that would
        // receive a click there; used to check the moved titlebar doesn't eat
        // clicks meant for the page.
        center.addObserver(forName: Notification.Name("ai.aureways.debug.hittest"), object: nil, queue: .main) { [weak self] note in
            guard let spec = note.object as? String else { return }
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            MainActor.assumeIsolated {
                guard let window = self?.hostView?.window, let frameView = window.contentView?.superview else { return }
                let point = NSPoint(x: parts[0], y: window.frame.height - parts[1])
                let hit = frameView.hitTest(point)
                var text = hit.map { String(describing: type(of: $0)) } ?? "nil"
                if hit === self?.composerPeer?.webView { text += " (composer)" }
                if let overlay = self?.composerPeer?.webView {
                    text += " overlay hidden=\(overlay.isHidden) frame=\(overlay.frame)"
                }
                if let close = window.standardWindowButton(.closeButton) {
                    text += " close=\(close.convert(close.bounds, to: nil)) super=\(String(describing: close.superview?.superview.map { type(of: $0) }))"
                }
                try? text.write(toFile: "/tmp/aureways_eval.out", atomically: true, encoding: .utf8)
            }
        }
        // Toggles the menu bar extra panel (clicks our status item button).
        // Opens the real MenuBarExtra panel with an in-process click on the
        // status item: "cg" posts a CGEvent click to this process only, "ax"
        // presses the button through its own accessibility action,
        // "app" routes NSEvents through NSApp.sendEvent. Logs what it finds.
        center.addObserver(forName: Notification.Name("ai.aureways.debug.statusItem"), object: nil, queue: .main) { note in
            let mode = note.object as? String ?? "cg"
            MainActor.assumeIsolated {
                var log: [String] = []
                guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible }),
                      let button = window.contentView.flatMap({ Self.firstSubview(of: NSButton.self, in: $0) }) else {
                    try? "no status item".write(toFile: "/tmp/aureways_eval.out", atomically: true, encoding: .utf8)
                    return
                }
                let local = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                log.append("status window \(window.frame) mode=\(mode)")
                if mode == "ax" {
                    log.append("accessibilityPerformPress=\(button.accessibilityPerformPress())")
                } else if mode == "app" {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.sendEvent(event)
                        }
                    }
                } else {
                    let screenPoint = window.convertPoint(toScreen: local)
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let cgPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cgPoint, mouseButton: .left)?
                            .postToPid(ProcessInfo.processInfo.processIdentifier)
                    }
                }
                try? log.joined(separator: "\n").write(toFile: "/tmp/aureways_eval.out", atomically: true, encoding: .utf8)
            }
        }
        // Finder drop without Accessibility: "path|path" (prefix "@composer "
        // to drop on the composer overlay instead of the main page).
        center.addObserver(forName: Notification.Name("ai.aureways.debug.drop"), object: nil, queue: .main) { [weak self] note in
            guard var spec = note.object as? String else { return }
            MainActor.assumeIsolated {
                var target = self?.webView as? ShellWebView
                if spec.hasPrefix("@composer ") {
                    spec.removeFirst("@composer ".count)
                    target = self?.composerPeer?.webView as? ShellWebView
                }
                let urls = spec.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
                target?.acceptDroppedFiles(urls)
            }
        }
        // The MenuBarExtra panel can't be opened without a real click, so this
        // hosts the same #menubar page in a plain panel next to the window.
        center.addObserver(forName: Notification.Name("ai.aureways.debug.menubarPanel"), object: nil, queue: .main) { [weak self] note in
            let close = (note.object as? String) == "close"
            MainActor.assumeIsolated {
                guard let self else { return }
                if close {
                    Self.debugMenuBarPanel?.close()
                    Self.debugMenuBarPanel = nil
                    return
                }
                let size = MenuBarWebView.size
                let anchor = self.hostView?.window?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
                let panel = NSPanel(contentRect: NSRect(x: anchor.maxX - size.width - 40, y: anchor.maxY - size.height - 60, width: size.width, height: size.height),
                                    styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
                panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true
                panel.isReleasedWhenClosed = false
                // Like the real MenuBarExtra window: above other apps' windows,
                // so WebKit doesn't treat the page as occluded/hidden.
                panel.level = .statusBar
                panel.contentView = WebShellHostView(model: self.model, role: .menuBar)
                panel.orderFront(nil)
                Self.debugMenuBarPanel = panel
            }
        }
        // Lists delivered user notifications and the Dock badge.
        center.addObserver(forName: Notification.Name("ai.aureways.debug.notifications"), object: nil, queue: .main) { _ in
            let badge = MainActor.assumeIsolated { NSApp.dockTile.badgeLabel ?? "" }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                    var lines = ["badge=\(badge) auth=\(settings.authorizationStatus.rawValue)"]
                    lines += delivered.map { "\($0.request.content.title) | \($0.request.content.body)" }
                    try? lines.joined(separator: "\n").write(toFile: "/tmp/aureways_eval.out", atomically: true, encoding: .utf8)
                }
            }
        }
        center.addObserver(forName: Notification.Name("ai.aureways.debug.fullscreen"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hostView?.window?.toggleFullScreen(nil)
            }
        }
        center.addObserver(forName: Notification.Name("ai.aureways.debug.frame"), object: nil, queue: .main) { [weak self] note in
            guard let spec = note.object as? String else { return }
            let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { return }
            MainActor.assumeIsolated {
                self?.hostView?.window?.setFrame(NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]), display: true, animate: false)
            }
        }
    }
    #endif

    // MARK: Menu bar extra

    /// Actions from the menu bar page that leave the panel. Returns true when handled.
    /// Commands the `#menubar` page posts (MenuBar.tsx). Kept as one list so a
    /// test can check the page and this handler agree: an unknown name used to
    /// fall through silently (the page posts `quitApp`, the handler only knew
    /// `quit`, so 退出 did nothing).
    enum MenuBarCommand: String, CaseIterable {
        case newSession, selectSession, openApp, openSettings, quitApp
        /// The panel became visible. Stale-only quota check; the menu bar never polls.
        case menuBarOpened

        init?(message type: String) {
            self.init(rawValue: type == "quit" ? "quitApp" : type)
        }
    }

    func handleMenuBar(_ type: String, _ body: [String: Any]) -> Bool {
        let dismiss = { [weak self] in self?.hostView?.window?.orderOut(nil) }
        guard let command = MenuBarCommand(message: type) else {
            switch type {
            case "dragRegions", "uiPrefs", "term.input", "term.resize", "term.close":
                return true
            default:
                return false
            }
        }
        switch command {
        case .menuBarOpened:
            model.quotaStore.request(reason: .menuBarOpened)
        case .newSession:
            dismiss()
            AppActivation.revealMainWindow()
            model.startNewSession()
            WebShellBridge.current?.sendCommand("focusComposer")
        case .selectSession:
            dismiss()
            AppActivation.revealMainWindow()
            if let session = session(body) { model.select(session) }
        case .openApp:
            dismiss()
            AppActivation.revealMainWindow()
        case .openSettings:
            dismiss()
            AppActivation.revealMainWindow()
            WebShellBridge.current?.sendCommand("openSettings")
        case .quitApp:
            dismiss()
            // Out of the WebKit message callback before terminating.
            DispatchQueue.main.async { MainActor.assumeIsolated { AppActivation.terminate() } }
        }
        return true
    }

    // MARK: Lifecycle

    func webWillReload() {
        isReady = false
        resetSentState()
    }

    func resetSentState() {
        lastStateJSON = ""
        transcriptSessionID = nil
        sentOrder = []
        sentItems = [:]
        sentRuns = [:]
    }

    func updateChrome(_ next: Chrome) {
        guard next != chrome else { return }
        chrome = next
        scheduleFlush()
    }

    /// Commands sent before the page is ready (e.g. Finder "Open With" at
    /// launch) are queued and replayed on `ready`.
    var queuedCommands: [[String: Any]] = []

    func sendCommand(_ name: String, _ extra: [String: Any] = [:]) {
        var payload = extra
        payload["type"] = "command"
        payload["name"] = name
        if role == .main {
            switch name {
            case "focusComposer":
                onFocusComposer?()
                composerPeer?.sendCommand(name, extra)
            case "dropHover", "dropEnd":
                composerPeer?.sendCommand(name, extra)
            case "find", "openSettings", "openMarkdown", "openReader", "toggleInspector":
                onFocusMain?()
            default:
                break
            }
        }
        guard isReady else {
            queuedCommands.append(payload)
            return
        }
        post(payload)
    }

    // MARK: Flush

    func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        let wait = max(0, Self.minFlushInterval - (CACurrentMediaTime() - lastFlushTime))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func flush() {
        flushPending = false
        lastFlushTime = CACurrentMediaTime()
        var outgoing: [[String: Any]] = []
        withObservationTracking {
            outgoing = self.collect()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleFlush() }
        }
        guard isReady else { return }
        for payload in outgoing { post(payload) }
    }

    func post(_ payload: [String: Any]) {
        guard isReady, let webView,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__aw&&window.__aw.receive(\(json))", completionHandler: nil)
    }

    /// Reads every observed property (so tracking re-arms) and returns messages.
    private func collect() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let appearance = model.appearance
        if appearance != lastAppearance {
            lastAppearance = appearance
            onAppearance?(appearance)
        }
        let state = encodeState()
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8), json != lastStateJSON {
            lastStateJSON = json
            out.append(["type": "state", "state": state])
        }
        if role == .main, let transcript = collectTranscript() {
            out.append(transcript)
        }
        return out
    }

    private func collectTranscript() -> [String: Any]? {
        guard let session = model.selectedSession else {
            if transcriptSessionID != nil {
                transcriptSessionID = nil
                sentOrder = []
                sentItems = [:]
                sentRuns = [:]
            }
            return nil
        }
        let items = session.items
        let runs = session.activityRuns
        _ = session.transcriptRevision
        if transcriptSessionID != session.id {
            transcriptSessionID = session.id
            sentOrder = items.map(\.id)
            sentItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            sentRuns = runs
            return [
                "type": "transcript",
                "sessionId": session.id.uuidString,
                "items": items.map { Self.encode($0, runs: runs) },
            ]
        }

        var ops: [[String: Any]] = []
        let newIDs = items.map(\.id)
        if newIDs != sentOrder {
            let live = Set(newIDs)
            for id in sentOrder where !live.contains(id) {
                ops.append(["op": "remove", "id": id.uuidString])
                sentItems[id] = nil
            }
        }
        for (index, item) in items.enumerated() {
            let id = item.id
            let runChanged = runs[id] != sentRuns[id]
            if let old = sentItems[id] {
                if old == item && !runChanged { continue }
                if !runChanged, let delta = Self.appendDelta(old: old, new: item) {
                    ops.append(["op": "append", "id": id.uuidString, "delta": delta])
                } else {
                    ops.append(["op": "upsert", "index": index, "item": Self.encode(item, runs: runs)])
                }
            } else {
                ops.append(["op": "upsert", "index": index, "item": Self.encode(item, runs: runs)])
            }
            sentItems[id] = item
        }
        sentOrder = newIDs
        sentRuns = runs
        guard !ops.isEmpty else { return nil }
        return ["type": "patch", "sessionId": session.id.uuidString, "ops": ops]
    }

    private static func appendDelta(old: TranscriptItem, new: TranscriptItem) -> String? {
        let before: String
        let after: String
        switch (old, new) {
        case (.agent(_, let a), .agent(_, let b)), (.thought(_, let a), .thought(_, let b)):
            before = a
            after = b
        default:
            return nil
        }
        let count = before.utf16.count
        guard count > 0, after.utf16.count > count, after.hasPrefix(before) else { return nil }
        let start = after.utf16.index(after.startIndex, offsetBy: count)
        return String(after[start...])
    }
}
