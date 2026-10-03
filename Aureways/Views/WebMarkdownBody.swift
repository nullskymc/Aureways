import AppKit
import SwiftUI
import WebKit

// MARK: - Feature flag

/// Prototype: render agent message Markdown in a WKWebView (marked + DOMPurify +
/// lazy Shiki, see `WebTranscript/`). Off by default; the SwiftUI renderer
/// (`MarkdownBody`) stays the default path.
///
///     defaults write ai.aureways.client useWebTranscript -bool true
enum WebTranscriptFlag {
    static let key = "useWebTranscript"

    static var isAvailable: Bool { WebTranscriptRuntime.shared.bundleRoot != nil }
}

// MARK: - SwiftUI entry point

/// Drop-in replacement for `MarkdownBody` inside an agent message.
///
/// Layout contract (the reason this is shaped the way it is): the web view never
/// reports a content-derived *width* upward. Width always comes from the
/// proposal; height comes from the page (`ResizeObserver` -> script message) and
/// is applied as a fixed `.frame(height:)`. Wide tables / code scroll inside the
/// page, so there is no ideal-width feedback into NavigationSplitView (the old
/// SIGABRT layout loop).
struct WebMarkdownBody: View {
    let messageID: String
    let source: String
    var isStreaming: Bool

    @State private var height: CGFloat

    init(messageID: String, source: String, isStreaming: Bool) {
        self.messageID = messageID
        self.source = source
        self.isStreaming = isStreaming
        let cached = WebTranscriptRuntime.shared.cachedHeight(for: messageID)
        _height = State(initialValue: cached ?? Self.estimatedHeight(for: source))
    }

    var body: some View {
        WebMarkdownRepresentable(
            messageID: messageID,
            source: source,
            isStreaming: isStreaming,
            height: $height
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(height, 1))
    }

    /// Rough first-frame height before the page has measured itself. Anything
    /// non-zero beats zero for the virtualized transcript's spacer math.
    static func estimatedHeight(for source: String) -> CGFloat {
        var lines = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, Int((Double(line.count) / 90).rounded(.up)))
        }
        return max(22, CGFloat(min(lines, 400)) * 21.6)
    }
}

private struct WebMarkdownRepresentable: NSViewRepresentable {
    let messageID: String
    let source: String
    let isStreaming: Bool
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> TranscriptWebView {
        let view = WebTranscriptRuntime.shared.checkout(messageID: messageID)
        bind(view)
        view.update(text: source, streaming: isStreaming)
        return view
    }

    func updateNSView(_ view: TranscriptWebView, context: Context) {
        if view.messageID != messageID {
            view.assign(messageID: messageID)
        }
        bind(view)
        view.update(text: source, streaming: isStreaming)
    }

    static func dismantleNSView(_ view: TranscriptWebView, coordinator: ()) {
        view.onHeight = nil
        WebTranscriptRuntime.shared.checkin(view)
    }

    /// Width = proposal (never content); height = measured page height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptWebView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: height)
    }

    private func bind(_ view: TranscriptWebView) {
        let binding = $height
        let id = messageID
        view.onHeight = { newHeight in
            WebTranscriptRuntime.shared.storeHeight(newHeight, for: id)
            if abs(binding.wrappedValue - newHeight) > 0.5 {
                binding.wrappedValue = newHeight
            }
        }
    }
}

// MARK: - Web view

/// One WKWebView hosting one agent message body. Reused through
/// `WebTranscriptRuntime` so scrolling a virtualized transcript does not pay
/// WKWebView creation + page load per row.
@MainActor
final class TranscriptWebView: WKWebView {
    private(set) var messageID: String?
    var onHeight: ((CGFloat) -> Void)?

    private var isReady = false
    private var pendingScripts: [String] = []

    // Desired vs. sent state; the throttle flushes the difference.
    private var desiredText = ""
    private var desiredStreaming = false
    private var sentText = ""
    private var sentStreaming = false
    private var hasSent = false
    private var flushScheduled = false
    private var lastFlush = Date.distantPast
    private static let streamingInterval: TimeInterval = 1.0 / 30.0

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        #if DEBUG
        isInspectable = true
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Never contribute an intrinsic size; SwiftUI drives the frame.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func assign(messageID: String) {
        guard self.messageID != messageID else { return }
        self.messageID = messageID
        desiredText = ""
        desiredStreaming = false
        sentText = ""
        sentStreaming = false
        hasSent = false
        enqueue("window.aureways.setMessages([])")
    }

    // MARK: Swift -> JS

    func update(text: String, streaming: Bool) {
        desiredText = text
        desiredStreaming = streaming
        guard !(hasSent && text == sentText && streaming == sentStreaming) else { return }
        if !streaming {
            flush() // final / static content: no throttle
            return
        }
        let elapsed = Date().timeIntervalSince(lastFlush)
        if elapsed >= Self.streamingInterval {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.streamingInterval - elapsed)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.flushScheduled = false
                    self?.flush()
                }
            }
        }
    }

    private func flush() {
        guard let messageID else { return }
        let text = desiredText
        let streaming = desiredStreaming
        guard !(hasSent && text == sentText && streaming == sentStreaming) else { return }
        lastFlush = Date()
        let id = Self.json(messageID)
        if hasSent, sentStreaming, text.hasPrefix(sentText) {
            let delta = String(text.dropFirst(sentText.count))
            if streaming {
                if !delta.isEmpty {
                    enqueue("window.aureways.appendDelta(\(id),\(Self.json(delta)))")
                }
            } else {
                // Full text on finish keeps JS authoritative-equal to Swift.
                enqueue("window.aureways.finishMessage(\(id),\(Self.json(text)))")
            }
        } else {
            let payload: [String: Any] = ["id": messageID, "text": text, "streaming": streaming]
            let data = (try? JSONSerialization.data(withJSONObject: [payload])) ?? Data("[]".utf8)
            enqueue("window.aureways.setMessages(\(String(decoding: data, as: UTF8.self)))")
        }
        sentText = text
        sentStreaming = streaming
        hasSent = true
    }

    private func enqueue(_ script: String) {
        if isReady {
            evaluateJavaScript(script, completionHandler: nil)
        } else {
            pendingScripts.append(script)
        }
    }

    private static func json(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        // Strip the array brackets: `["…"]` -> `"…"`.
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    // MARK: JS -> Swift

    func pageDidBecomeReady() {
        isReady = true
        let scripts = pendingScripts
        pendingScripts.removeAll()
        for script in scripts {
            evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func contentProcessDidTerminate() {
        isReady = false
        pendingScripts.removeAll()
        hasSent = false
        sentText = ""
        sentStreaming = false
        WebTranscriptRuntime.shared.load(self)
        update(text: desiredText, streaming: desiredStreaming)
    }

    func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            pageDidBecomeReady()
        case "height":
            if let value = (dict["height"] as? NSNumber)?.doubleValue {
                onHeight?(CGFloat(value))
            }
        case "link":
            if let href = dict["href"] as? String {
                WebTranscriptRuntime.openExternally(href)
            }
        case "copy":
            if let text = dict["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }

    // MARK: Native feel

    /// The page never scrolls vertically (the transcript's ScrollView does), so
    /// hand vertical-dominant wheel events to the enclosing scroll view. Keep
    /// horizontal ones for tables / code blocks that overflow.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            if let scrollView = enclosingScrollView {
                scrollView.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Drop browser-ish items (Reload, Back, Inspect Element, Open Link in New
    /// Window, Download…). Keep Copy, Copy Link, Look Up, Translate, Speech, Share.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let allowed: Set<String> = [
            "WKMenuItemIdentifierCopy",
            "WKMenuItemIdentifierCopyLink",
            "WKMenuItemIdentifierLookUp",
            "WKMenuItemIdentifierTranslate",
            "WKMenuItemIdentifierSearchWeb",
            "WKMenuItemIdentifierSpeechMenu",
            "WKMenuItemIdentifierShareMenu",
        ]
        for item in menu.items.reversed() {
            let id = item.identifier?.rawValue ?? ""
            #if DEBUG
            if id == "WKMenuItemIdentifierInspectElement" { continue }
            #endif
            if item.isSeparatorItem { continue }
            if !allowed.contains(id) {
                menu.removeItem(item)
            }
        }
        // Tidy separators left at the edges or doubled up.
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        var previousWasSeparator = false
        for item in menu.items.reversed() {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
        super.willOpenMenu(menu, with: event)
    }
}
