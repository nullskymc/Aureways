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
final class WebShellBridge: NSObject, WKScriptMessageHandler {
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

    private(set) var isReady = false
    private var flushPending = false
    private var lastFlushTime: CFTimeInterval = 0
    private static let minFlushInterval: CFTimeInterval = 1.0 / 45.0
    private var lastStateJSON = ""
    private var lastAppearance: String?
    private var chrome = Chrome(trafficLights: .zero, fullscreen: false, titlebarHeight: 46)

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
    private var uiPrefs: [String: Any] = UserDefaults.standard.dictionary(forKey: WebShellBridge.uiPrefsKey) ?? [:]

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

        init?(message type: String) {
            self.init(rawValue: type == "quit" ? "quitApp" : type)
        }
    }

    private func handleMenuBar(_ type: String, _ body: [String: Any]) -> Bool {
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

    private func resetSentState() {
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
    private var queuedCommands: [[String: Any]] = []

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
            case "find", "openSettings", "openMarkdown":
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

    private func flush() {
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

    // MARK: State snapshot

    private func encodeState() -> [String: Any] {
        let selected = model.selectedSession
        let sessions = model.sessions.filter { !$0.isClosed }
        var state: [String: Any] = [
            "locale": L10n.locale.language.languageCode?.identifier == "zh" ? "zh" : "en",
            "appearance": model.appearance,
            "selectedSessionId": selected?.id.uuidString ?? NSNull(),
            "selectedAgentId": model.selectedAgentId,
            "workspacePath": WorkspaceRecord.normalized(model.workspacePath),
            "workspaceName": model.currentWorkspaceName,
            "branch": model.workspaceBranch ?? NSNull(),
            "homePath": WorkspaceRecord.homePath,
            "error": model.errorMessage ?? NSNull(),
            "chrome": [
                "trafficLights": [
                    "x": chrome.trafficLights.minX, "y": chrome.trafficLights.minY,
                    "w": chrome.trafficLights.width, "h": chrome.trafficLights.height,
                ],
                "fullscreen": chrome.fullscreen,
                "titlebarHeight": chrome.titlebarHeight,
                "glass": role != .menuBar,
                "composerOverlay": role == .main,
            ],
        ]
        state["workspaces"] = model.workspaces.map { ["path": WorkspaceRecord.normalized($0.path), "name": $0.name] }
        state["agents"] = model.selectableAgents.map { agent -> [String: Any] in
            [
                "id": agent.id,
                "title": agent.title,
                "subtitle": agent.subtitle,
                "available": model.availability[agent.id] == true,
            ]
        }
        state["sessions"] = sessions.map { session -> [String: Any] in
            var row: [String: Any] = [
                "id": session.id.uuidString,
                "title": session.title,
                "agentId": session.agent.id,
                "agentTitle": session.agent.title,
                "cwd": session.cwd,
                "ws": WorkspaceRecord.normalized(session.cwd),
                "phase": Self.phaseName(session.phase),
                "streaming": session.isStreaming,
                "attention": session.pendingPermission != nil || session.pendingPlanApproval != nil
                    || session.pendingUserQuestion != nil,
                "createdAt": session.createdAt.timeIntervalSince1970 * 1000,
            ]
            if case .failed(let message) = session.phase { row["error"] = message }
            // Cross-session cards: the web shows these for sessions that aren't selected.
            if session.id != selected?.id {
                if let prompt = session.pendingPermission {
                    row["permission"] = Self.encode(prompt)
                } else if session.pendingPlanApproval != nil {
                    row["pendingKind"] = "plan"
                } else if session.pendingUserQuestion != nil {
                    row["pendingKind"] = "question"
                }
            }
            return row
        }
        if role == .main { notifier.update(sessions: sessions, selectedID: selected?.id) }
        state["uiPrefs"] = uiPrefs
        state["settings"] = encodeSettings()
        state["quota"] = encodeQuota()
        state["inspectorRoot"] = model.inspectorRoot
        state["composer"] = encodeComposer(selected)
        if let selected {
            if let prompt = selected.pendingPermission {
                state["permission"] = Self.encode(prompt)
            }
            if let plan = selected.pendingPlanApproval {
                state["planApproval"] = ["content": plan.content, "filePath": Self.orNull(plan.filePath)] as [String: Any]
            }
            if let question = selected.pendingUserQuestion {
                state["question"] = [
                    "questions": question.questions.map { q -> [String: Any] in
                        [
                            "id": q.id.uuidString,
                            "text": q.text,
                            "multi": q.multiSelect,
                            "options": q.options.map { option -> [String: Any] in ["label": option.label, "description": Self.orNull(option.description)] },
                        ]
                    },
                ]
            }
            if let usage = selected.usage {
                state["usage"] = ["used": usage.used, "size": usage.size]
            }
        }
        return state
    }

    private func encodeComposer(_ session: ChatSession?) -> [String: Any] {
        var composer: [String: Any] = [
            "attachments": pendingAttachments.map { attachment -> [String: Any] in
                var row: [String: Any] = [
                    "id": attachment.id.uuidString,
                    "name": attachment.name,
                    "kind": Self.attachmentKind(attachment.kind),
                ]
                if let path = attachment.url?.path { row["path"] = path }
                if attachment.characterCount > 0 { row["chars"] = attachment.characterCount }
                if attachment.kind == .image, let data = attachment.imageData, data.count < 4_000_000 {
                    row["src"] = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
                }
                return row
            },
        ]
        guard let session else { return composer }
        composer["sessionId"] = session.id.uuidString
        composer["commands"] = session.availableCommands.map { ["name": $0.name, "description": $0.description ?? ""] }
        guard session.phase.isReady else { return composer }
        if let option = session.modelOption, !option.options.isEmpty {
            composer["model"] = Self.encodePicker(configId: option.id, current: option.selectedString, choices: option.options)
        }
        if let option = session.thoughtLevelOption, !option.options.isEmpty {
            composer["effort"] = Self.encodePicker(configId: option.id, current: option.selectedString, choices: option.options)
        }
        if !session.modeChoices.isEmpty {
            composer["mode"] = Self.encodePicker(configId: nil, current: session.currentModeId, choices: session.modeChoices)
        }
        return composer
    }

    private static func encodePicker(configId: String?, current: String?, choices: [SessionMode]) -> [String: Any] {
        [
            "configId": configId ?? NSNull(),
            "current": current ?? NSNull(),
            "options": choices.map { choice -> [String: Any] in
                ["id": choice.id, "name": choice.name, "group": orNull(choice.providerLabel),
                 "description": orNull(choice.description)]
            },
        ]
    }

    private static func orNull(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func attachmentKind(_ kind: ComposerAttachment.Kind) -> String {
        switch kind {
        case .image: return "image"
        case .file: return "file"
        case .pastedText: return "pastedText"
        }
    }

    private static func phaseName(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    // MARK: Transcript encoding

    static func encode(_ item: TranscriptItem, runs: [UUID: ActivityRun]) -> [String: Any] {
        var row: [String: Any]
        switch item {
        case .user(let id, let text, let attachments):
            row = [
                "id": id.uuidString, "kind": "user", "text": text,
                "attachments": attachments.map(encode(attachment:)),
            ]
        case .agent(let id, let text):
            row = ["id": id.uuidString, "kind": "agent", "text": text]
        case .thought(let id, let text):
            row = ["id": id.uuidString, "kind": "thought", "text": text]
        case .tool(let id, let call):
            row = encode(tool: call)
            row["id"] = id.uuidString
            row["kind"] = "tool"
        case .plan(let id, let entries):
            row = [
                "id": id.uuidString, "kind": "plan",
                "entries": entries.map { ["content": $0.content, "status": $0.status] },
            ]
        case .status(let id, let text):
            row = ["id": id.uuidString, "kind": "status", "text": text]
        }
        if let run = runs[item.id] {
            row["run"] = [
                "s": run.startedAt.timeIntervalSince1970 * 1000,
                "e": run.endedAt.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull(),
            ]
        }
        return row
    }

    static func encode(attachment: TranscriptAttachment) -> [String: Any] {
        var row: [String: Any] = [
            "id": attachment.id.uuidString,
            "kind": attachment.isPastedText ? "pastedText" : attachment.kind,
            "name": attachment.name,
        ]
        if let path = attachment.path { row["path"] = path }
        if attachment.characterCount > 0 { row["chars"] = attachment.characterCount }
        if attachment.kind == "image", let base64 = attachment.imageBase64, !base64.isEmpty, base64.utf8.count < 6_000_000 {
            if base64.hasPrefix("data:") {
                row["src"] = base64
            } else {
                row["src"] = "data:\(attachment.mimeType ?? "image/png");base64,\(base64)"
            }
        }
        return row
    }

    private static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    private static let outputLimit = 24_000
    private static let diffLineLimit = 600

    static func encode(tool call: ToolCallView) -> [String: Any] {
        var row: [String: Any] = [
            "callId": call.toolCallId,
            "title": call.compactTitle,
            "fullTitle": call.displayTitle,
            "toolKind": call.kind,
            "status": call.status.lowercased(),
            "layout": call.cardLayout.rawValue,
            "progress": call.showsProgress,
        ]
        if let path = call.filePath { row["path"] = path }
        switch call.cardLayout {
        case .command:
            if let command = call.terminalCommand { row["command"] = command }
            if let cwd = call.terminalCwd { row["cwd"] = cwd }
            if let output = call.terminalOutput, !output.isEmpty { row["output"] = tail(output) }
            if let code = call.terminalExitCode { row["exitCode"] = code }
        case .search:
            if let pattern = call.searchPattern { row["pattern"] = pattern }
            if !call.contentText.isEmpty { row["output"] = head(call.contentText) }
        case .fetch:
            if let url = call.fetchURL { row["url"] = url }
            if !call.contentText.isEmpty { row["output"] = head(call.contentText) }
        default:
            if !call.contentText.isEmpty { row["output"] = head(call.contentText) }
        }
        let diffs = call.diffs
        if !diffs.isEmpty {
            var budget = diffLineLimit
            row["diffs"] = diffs.map { diff -> [String: Any] in
                let result = TextDiff.compare(old: diff.oldText, new: diff.newText)
                var hunks: [[String: Any]] = []
                for hunk in result.hunks where budget > 0 {
                    let lines = hunk.lines.prefix(budget)
                    budget -= lines.count
                    hunks.append([
                        "header": hunk.header,
                        "oldStart": hunk.oldStart,
                        "newStart": hunk.newStart,
                        "lines": lines.map { $0.prefix + $0.text },
                    ])
                }
                return [
                    "path": diff.path,
                    "added": result.added,
                    "removed": result.removed,
                    "truncated": result.truncated || budget <= 0,
                    "isNew": diff.oldText == nil || diff.oldText?.isEmpty == true,
                    "hunks": hunks,
                ]
            }
        }
        if row["output"] == nil, diffs.isEmpty, let raw = call.rawInput,
           let data = try? Self.prettyEncoder.encode(raw), data.count < 8_000,
           let text = String(data: data, encoding: .utf8), text != "{}", text != "null" {
            row["input"] = text
        }
        return row
    }

    static func encode(_ prompt: PermissionPrompt) -> [String: Any] {
        var row: [String: Any] = [
            "title": prompt.title,
            "options": prompt.options.map { option -> [String: Any] in
                ["id": option.optionId, "name": option.name, "kind": option.kind, "allow": option.isAllow]
            },
        ]
        if let tool = prompt.toolCall { row["tool"] = encode(tool: tool) }
        return row
    }

    private static func head(_ text: String) -> String {
        guard text.utf16.count > outputLimit else { return text }
        let end = text.utf16.index(text.startIndex, offsetBy: outputLimit)
        return String(text[..<end]) + "\n…"
    }

    private static func tail(_ text: String) -> String {
        let count = text.utf16.count
        guard count > outputLimit else { return text }
        let start = text.utf16.index(text.startIndex, offsetBy: count - outputLimit)
        return "…\n" + String(text[start...])
    }

    // MARK: JS -> Swift

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        handle(type, body)
    }

    private func session(_ body: [String: Any], key: String = "id") -> ChatSession? {
        guard let raw = body[key] as? String, let id = UUID(uuidString: raw) else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private func handle(_ type: String, _ body: [String: Any]) {
        if role == .menuBar, handleMenuBar(type, body) { return }
        if role == .composer {
            switch type {
            case "composerLayout":
                onComposerLayout?(body)
                return
            case "composerEscape":
                WebShellBridge.current?.sendCommand("escape")
                return
            case "uiPrefs", "dragRegions", "glass":
                return
            default:
                break
            }
        }
        switch type {
        case "ready":
            isReady = true
            resetSentState()
            flush()
            let queued = queuedCommands
            queuedCommands = []
            queued.forEach(post)
            onReady?()
        case "log":
            NSLog("[web] %@", String(describing: body["message"] ?? ""))
        case "send":
            let text = body["text"] as? String ?? ""
            let attachments = pendingAttachments
            model.sendFromComposer(text: text, attachments: attachments)
            pendingAttachments = []
        case "cancel":
            model.cancel()
        case "newSession":
            if let path = body["workspace"] as? String, !path.isEmpty {
                model.startNewSession(inWorkspace: path)
            } else {
                model.startNewSession()
            }
            sendCommand("focusComposer")
        case "selectSession":
            if let session = session(body) { model.select(session) }
        case "closeSession":
            if let session = session(body) { model.close(session) }
        case "retry":
            if let session = session(body) ?? model.selectedSession { model.retry(session) }
        case "selectAgent":
            if let id = body["id"] as? String, model.agents.contains(where: { $0.id == id }) {
                model.selectedAgentId = id
            }
        case "setConfig":
            if let session = model.selectedSession, let configId = body["configId"] as? String,
               let value = body["value"] as? String {
                model.setSessionConfig(session, configId: configId, value: .string(value))
            }
        case "setMode":
            if let session = model.selectedSession, let modeId = body["modeId"] as? String {
                model.setSessionMode(session, modeId: modeId)
            }
        case "permission":
            guard let session = session(body, key: "sessionId") ?? model.selectedSession,
                  session.pendingPermission != nil else { return }
            if let optionId = body["optionId"] as? String {
                session.resumePermission(.selected(optionId))
            } else {
                session.resumePermission(.cancelled)
            }
        case "planApproval":
            guard let session = model.selectedSession, session.pendingPlanApproval != nil else { return }
            switch body["decision"] as? String {
            case "approve": session.resumePlanApproval(.approved(feedback: body["feedback"] as? String ?? ""))
            case "changes": session.resumePlanApproval(.requestChanges)
            default: session.resumePlanApproval(.quit)
            }
        case "question":
            guard let session = model.selectedSession, let prompt = session.pendingUserQuestion else { return }
            if body["skip"] as? Bool == true {
                session.resumeUserQuestion(.skipInterview)
                return
            }
            let answers = body["answers"] as? [String: [String]] ?? [:]
            var mapped: [UUID: [String]] = [:]
            for question in prompt.questions {
                mapped[question.id] = answers[question.id.uuidString] ?? []
            }
            session.resumeUserQuestion(.accepted(mapped))
        case "rpc":
            handleRPC(body)
        case "term.input":
            if let id = body["id"] as? String, let data = body["data"] as? String { terminals.input(id: id, data: data) }
        case "term.resize":
            if let id = body["id"] as? String {
                terminals.resize(id: id, cols: (body["cols"] as? NSNumber)?.intValue ?? 0, rows: (body["rows"] as? NSNumber)?.intValue ?? 0)
            }
        case "term.close":
            if let id = body["id"] as? String { terminals.close(id: id) }
        case "uiPrefs":
            if let prefs = body["prefs"] as? [String: Any] {
                for (key, value) in prefs { uiPrefs[key] = value is NSNull ? nil : value }
                UserDefaults.standard.set(uiPrefs, forKey: Self.uiPrefsKey)
            }
        case "pasteNative":
            let attachments = ComposerAttachment.fromPasteboard(.general)
            if attachments.isEmpty {
                sendCommand("pasteFallback")
            } else {
                pendingAttachments.append(contentsOf: attachments)
            }
        case "pasteImage":
            if let base64 = body["data"] as? String, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                pendingAttachments.append(ComposerAttachment(
                    kind: .image, name: body["name"] as? String ?? "图片".localized, url: nil,
                    mimeType: body["mime"] as? String ?? "image/png", imageData: data, thumbnail: image
                ))
            }
        case "attachPaths":
            let urls = (body["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            pendingAttachments.append(contentsOf: ComposerAttachment.fromFileURLs(urls))
        case "openPastedText":
            if let raw = body["id"] as? String, let attachment = pendingAttachments.first(where: { $0.id.uuidString == raw }),
               let path = attachment.url?.path {
                openFiles([path])
            }
        case "attach":
            presentOpenPanel()
        case "removeAttachment":
            if let raw = body["id"] as? String, let attachment = pendingAttachments.first(where: { $0.id.uuidString == raw }) {
                if attachment.kind == .pastedText { model.discardPastedTextDraft(attachment) }
                pendingAttachments.removeAll { $0.id == attachment.id }
            }
        case "pasteText":
            if let text = body["text"] as? String, let attachment = model.capturePastedText(text) {
                pendingAttachments.append(attachment)
            }
        case "openLink":
            if let href = body["href"] as? String { WebAssetSchemeHandler.openExternally(href) }
        case "openPath":
            if let path = body["path"] as? String, !path.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "selectWorkspace":
            if let path = body["path"] as? String { model.selectWorkspace(path) }
        case "addWorkspace":
            model.addWorkspace()
        case "revealWorkspace":
            model.openWorkspaceInFinder(body["path"] as? String)
        case "openSettings":
            sendCommand("openSettings")
        case "dismissError":
            model.errorMessage = nil
        case "dragRegions":
            let rects = (body["rects"] as? [[String: Any]] ?? []).compactMap { rect -> CGRect? in
                guard let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
                      let w = (rect["w"] as? NSNumber)?.doubleValue, let h = (rect["h"] as? NSNumber)?.doubleValue
                else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
            onDragRegions?(rects, (body["height"] as? NSNumber).map { CGFloat($0.doubleValue) })
        case "composerInsert":
            if let text = body["text"] as? String { composerPeer?.sendCommand("insertText", ["text": text]) }
        case "glass":
            let panels = (body["rects"] as? [[String: Any]] ?? []).compactMap { rect -> GlassLayerView.Panel? in
                func number(_ key: String) -> CGFloat? { (rect[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
                guard let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"), w > 0, h > 0
                else { return nil }
                var extra: [String: CGFloat] = [:]
                for key in ["al", "ar", "mw"] { extra[key] = number(key) }
                return GlassLayerView.Panel(kind: rect["k"] as? String ?? "", frame: CGRect(x: x, y: y, width: w, height: h), radius: number("r") ?? 12, extra: extra)
            }
            onGlassRects?(panels)
        case "menu":
            let token = (body["token"] as? NSNumber)?.intValue ?? 0
            let items = body["items"] as? [[String: Any]] ?? []
            let point = CGPoint(x: (body["x"] as? NSNumber)?.doubleValue ?? 0, y: (body["y"] as? NSNumber)?.doubleValue ?? 0)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let chosen = self.popUpMenu(items, at: point)
                    self.post(["type": "menuResult", "token": token, "id": chosen ?? NSNull()])
                }
            }
        case "sessionMenu":
            guard let session = session(body) else { return }
            let point = CGPoint(x: (body["x"] as? NSNumber)?.doubleValue ?? 0, y: (body["y"] as? NSNumber)?.doubleValue ?? 0)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.showSessionMenu(session, at: point) }
            }
        default:
            NSLog("[web] unknown message %@", type)
        }
    }

    // MARK: Native UI helpers

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: model.inspectorRoot)
        panel.prompt = "添加".localized
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            self.pendingAttachments.append(contentsOf: ComposerAttachment.fromFileURLs(panel.urls))
        }
        if let window = hostView?.window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private final class MenuTarget: NSObject {
        var chosen: String?
        @objc func pick(_ sender: NSMenuItem) { chosen = sender.representedObject as? String }
    }

    /// Items: `{id, title, subtitle?, checked?, disabled?, icon? (SF Symbol)}`,
    /// `{type: "separator"}`, `{type: "header", title}`.
    private func popUpMenu(_ specs: [[String: Any]], at point: CGPoint) -> String? {
        guard let hostView else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget()
        for spec in specs {
            let title = spec["title"] as? String ?? ""
            switch spec["type"] as? String {
            case "separator":
                menu.addItem(.separator())
                continue
            case "header":
                menu.addItem(.sectionHeader(title: title))
                continue
            default:
                break
            }
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = spec["id"] as? String
            item.state = (spec["checked"] as? Bool == true) ? .on : .off
            item.isEnabled = spec["disabled"] as? Bool != true
            if let subtitle = spec["subtitle"] as? String, !subtitle.isEmpty { item.subtitle = subtitle }
            if let icon = spec["icon"] as? String {
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: hostView)
        return target.chosen
    }

    private func showSessionMenu(_ session: ChatSession, at point: CGPoint) {
        var items: [[String: Any]] = [
            ["id": "reveal", "title": "在 Finder 中显示".localized, "icon": "folder"],
            ["id": "copyId", "title": "复制会话 ID".localized, "icon": "doc.on.doc",
             "disabled": session.acpSessionId == nil],
            ["type": "separator"],
            ["id": "close", "title": "关闭会话".localized, "icon": "xmark.circle"],
            ["id": "forget", "title": "从列表移除".localized, "icon": "eye.slash"],
        ]
        if model.canDelete(session) {
            items.append(["id": "delete", "title": "删除会话".localized, "icon": "trash"])
        }
        switch popUpMenu(items, at: point) {
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        case "copyId":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.acpSessionId ?? "", forType: .string)
        case "close":
            model.close(session)
        case "forget":
            model.forget(session)
        case "delete":
            model.delete(session)
        default:
            break
        }
    }
}
