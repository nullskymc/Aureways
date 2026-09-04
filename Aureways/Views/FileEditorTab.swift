import AppKit
import SwiftUI

// MARK: - File Editor Tab

struct FileEditorTabView: View {
    @Environment(AppModel.self) private var model
    let path: String
    var isActive: Bool = true

    private var state: FileTabState? { model.fileTabStates[path] }
    private var visual: FileVisual { FileVisual.for(path: path) }

    var body: some View {
        VStack(spacing: 0) {
            FileEditorHeader(path: path, state: state, visual: visual)
                .frame(minHeight: 32)
                .fixedSize(horizontal: false, vertical: true)
                .background(Palette.inspectorBg)

            Divider()
                .overlay(Palette.splitDivider)

            if state?.externallyModified == true {
                externalChangeBanner
                Divider()
                    .overlay(Palette.splitDivider)
            }

            TextEditorRepresentable(path: path, isActive: isActive)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            Divider()
                .overlay(Palette.splitDivider)

            FileEditorStatusBar(path: path, state: state, visual: visual)
                .fixedSize(horizontal: false, vertical: true)
                .background(Palette.inspectorBg)
        }
        .background(Palette.inspectorBg)
    }

    private var externalChangeBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.gold)
                Text("文件已被 Agent 或外部修改")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("重新载入") {
                    model.reloadFileTab(path)
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("保留我的") {
                    model.keepEditedFileTab(path)
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.gold.opacity(0.10))
    }
}

// MARK: - File Editor Header

private struct FileEditorHeader: View {
    @Environment(AppModel.self) private var model
    let path: String
    let state: FileTabState?
    let visual: FileVisual

    @State private var isCopyHovered = false
    @State private var isExternalHovered = false
    @State private var isFinderHovered = false
    @State private var isReloadHovered = false
    @State private var copiedFeedback = false

    private var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private var breadcrumbPath: String {
        let workspace = model.workspacePath
        let rootName = URL(fileURLWithPath: workspace).lastPathComponent
        let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
        guard path.hasPrefix(prefix) else {
            return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }
        // 只能用字符串切：URL(fileURLWithPath:) 会把相对路径按进程 CWD 解析成绝对路径。
        let parent = (String(path.dropFirst(prefix.count)) as NSString).deletingLastPathComponent
        return parent.isEmpty ? rootName : "\(rootName) › \(parent)"
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Text(breadcrumbPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0)

                Text("›")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Image(systemName: visual.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(visual.color)

                Text(fileName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(minWidth: 0)
                    .layoutPriority(1)

                if state?.isDirty == true {
                    Circle()
                        .fill(Palette.gold)
                        .frame(width: 5, height: 5)
                        .help("未保存")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 1) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedFeedback = false
                    }
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(copiedFeedback ? Palette.accent : (isCopyHovered ? .primary : .secondary))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(isCopyHovered ? Color.primary.opacity(0.06) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isCopyHovered = $0 }
                .help(copiedFeedback ? "已复制路径" : "复制完整路径")

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isExternalHovered ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(isExternalHovered ? Color.primary.opacity(0.06) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isExternalHovered = $0 }
                .help("在默认外部编辑器中打开")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isFinderHovered ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(isFinderHovered ? Color.primary.opacity(0.06) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isFinderHovered = $0 }
                .help("在 Finder 中显示")

                Button {
                    model.requestReloadFileTab(path)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isReloadHovered ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(isReloadHovered ? Color.primary.opacity(0.06) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isReloadHovered = $0 }
                .help("重新从磁盘载入")
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - File Editor Status Bar

private struct FileEditorStatusBar: View {
    @Environment(AppModel.self) private var model
    let path: String
    let state: FileTabState?
    let visual: FileVisual

    /// 行数与体积都取内存里的草稿：这个视图随每次按键重渲染，
    /// 读盘等于在每个键击上把整个文件（上限 2MB）重新解码一遍。
    private var draft: String? { model.editorDrafts[path] }

    private var lineCount: Int {
        guard let draft, !draft.isEmpty else { return 0 }
        var count = 1
        for byte in draft.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    private var fileSizeString: String {
        guard let draft else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(draft.utf8.count), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(visual.color)
                    .frame(width: 6, height: 6)
                Text(visual.language)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            ViewThatFits(in: .horizontal) {
                metaRow(includeSize: true, includeEncoding: true)
                metaRow(includeSize: false, includeEncoding: true)
                metaRow(includeSize: false, includeEncoding: false)
                EmptyView()
            }

            Spacer(minLength: 4)

            if state?.isDirty == true {
                Text("⌘S 保存")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.gold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.gold.opacity(0.12))
                    )
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.inspectorBg)
    }

    @ViewBuilder
    private func metaRow(includeSize: Bool, includeEncoding: Bool) -> some View {
        HStack(spacing: 8) {
            if draft != nil {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("共 \(lineCount) 行")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if includeSize, !fileSizeString.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(fileSizeString)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if includeEncoding {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("UTF-8")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - NSTextView wrapper

/// 行号画在滚动视图旁边，不用 NSRulerView：系统尺会盖住 documentView，正文排好了也看不见。
private final class EditorHostView: NSView {
    static let gutterWidth: CGFloat = 40

    let scrollView = NSScrollView()
    let gutter = LineNumberGutterView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(gutter)
        addSubview(scrollView)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redrawGutter),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func attach(_ textView: SaveTextView) {
        scrollView.documentView = textView
        gutter.textView = textView
        gutter.scrollView = scrollView
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redrawGutter),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    @objc private func redrawGutter() {
        gutter.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        gutter.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: height)
        scrollView.frame = NSRect(
            x: Self.gutterWidth,
            y: 0,
            width: max(0, bounds.width - Self.gutterWidth),
            height: height
        )
        syncTextViewSize()
        gutter.needsDisplay = true
    }

    func syncTextViewSize() {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let width = max(scrollView.contentSize.width, 1)
        textView.minSize = NSSize(width: 0, height: max(scrollView.contentSize.height, 0))
        if abs(textView.frame.width - width) > 0.5 {
            textView.frame.size.width = width
        }
        textView.textContainer?.widthTracksTextView = true
    }
}

private final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.editorCanvasNS.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: bounds.minY, width: 0.5, height: bounds.height).fill()

        guard let textView, let scrollView else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            drawWithLayoutManager(layoutManager, container: container, textView: textView, scrollView: scrollView, attrs: attrs)
            return
        }
        drawFallbackLine(attrs: attrs)
    }

    private func drawWithLayoutManager(
        _ layoutManager: NSLayoutManager,
        container: NSTextContainer,
        textView: NSTextView,
        scrollView: NSScrollView,
        attrs: [NSAttributedString.Key: Any]
    ) {
        let visibleRect = scrollView.documentVisibleRect
        let containerOrigin = textView.textContainerOrigin
        let boundingRect = visibleRect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: boundingRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString

        var lineNumber = 1
        if charRange.location > 0 {
            lineNumber += (string.substring(to: charRange.location) as NSString).components(separatedBy: "\n").count - 1
        }

        if string.length == 0 {
            drawLabel("1", y: textView.textContainerInset.height, height: 16, attrs: attrs)
            return
        }

        var index = charRange.location
        while index < NSMaxRange(charRange) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil).location
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + containerOrigin.y - visibleRect.minY
            if y + lineRect.height >= 0, y <= bounds.height {
                drawLabel("\(lineNumber)", y: y, height: lineRect.height, attrs: attrs)
            }
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
    }

    private func drawFallbackLine(attrs: [NSAttributedString.Key: Any]) {
        drawLabel("1", y: 8, height: 16, attrs: attrs)
    }

    private func drawLabel(_ text: String, y: CGFloat, height: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let label = text as NSString
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: bounds.maxX - size.width - 8, y: y + (height - size.height) / 2),
            withAttributes: attrs
        )
    }
}

private final class SaveTextView: NSTextView {
    var saveHandler: (() -> Void)?
    fileprivate static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        typingAttributes = [
            .font: Self.editorFont,
            .foregroundColor: NSColor.labelColor,
        ]
        insertionPointColor = .labelColor
        if let storage = textStorage, storage.length > 0 {
            storage.addAttributes([
                .font: Self.editorFont,
                .foregroundColor: NSColor.labelColor,
            ], range: NSRange(location: 0, length: storage.length))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            saveHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct TextEditorRepresentable: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let path: String
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, path: path)
    }

    func makeNSView(context: Context) -> EditorHostView {
        let host = EditorHostView()
        // 默认构造与 Composer 相同，走系统 TextKit 装配；不要 usingTextLayoutManager: false。
        let textView = SaveTextView()
        textView.delegate = context.coordinator
        textView.saveHandler = { context.coordinator.save() }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = SaveTextView.editorFont
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: max(host.scrollView.contentSize.width, 1), height: max(host.scrollView.contentSize.height, 1))

        host.attach(textView)
        context.coordinator.textView = textView
        context.coordinator.host = host
        context.coordinator.loadContent()
        return host
    }

    func updateNSView(_ nsView: EditorHostView, context: Context) {
        context.coordinator.model = model
        context.coordinator.host = nsView
        context.coordinator.syncReload()
        nsView.syncTextViewSize()
        nsView.gutter.needsDisplay = true
        context.coordinator.updateFirstResponder(isActive: isActive, scrollView: nsView.scrollView)
    }
}

@MainActor
private final class Coordinator: NSObject, NSTextViewDelegate {
    var model: AppModel
    let path: String
    weak var textView: SaveTextView?
    weak var host: EditorHostView?
    private var loadedReloadToken = 0
    private var applyingProgrammaticChange = false
    private var wasActive = false
    private var didApplyActiveState = false

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
    }

    func loadContent() {
        if let draft = model.editorDrafts[path] {
            apply(draft, persistDraft: false)
        } else {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                apply(text, persistDraft: true)
            } else {
                applyingProgrammaticChange = true
                textView?.string = "（无法读取文件内容）"
                textView?.font = NSFont.systemFont(ofSize: 12)
                textView?.isEditable = false
                applyingProgrammaticChange = false
                host?.gutter.needsDisplay = true
            }
        }
        loadedReloadToken = model.fileTabStates[path]?.reloadToken ?? 0
    }

    func syncReload() {
        let token = model.fileTabStates[path]?.reloadToken ?? 0
        guard token != loadedReloadToken else { return }
        loadContent()
    }

    func updateFirstResponder(isActive: Bool, scrollView: NSScrollView) {
        // 非活动标签只是 opacity(0) 但仍然存活，NSTextView 会继续握着 first responder，
        // 这时打字会改到看不见的文件并把它标脏。
        guard let window = scrollView.window, let textView else { return }
        if !didApplyActiveState {
            didApplyActiveState = true
            wasActive = isActive
            if !isActive, window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
            return
        }
        let becameActive = isActive && !wasActive
        wasActive = isActive
        if !isActive {
            if window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
            return
        }
        if becameActive, window.firstResponder == nil {
            window.makeFirstResponder(textView)
        }
    }

    func save() {
        guard let text = textView?.string else { return }
        model.saveFileTab(path: path, content: text)
    }

    private func apply(_ text: String, persistDraft: Bool) {
        applyingProgrammaticChange = true
        textView?.string = text
        textView?.font = SaveTextView.editorFont
        textView?.isEditable = true
        if let storage = textView?.textStorage, storage.length > 0 {
            storage.addAttributes([
                .font: SaveTextView.editorFont,
                .foregroundColor: NSColor.labelColor,
            ], range: NSRange(location: 0, length: storage.length))
        }
        applyingProgrammaticChange = false
        host?.gutter.needsDisplay = true
        if persistDraft, model.editorDrafts[path] != text {
            model.editorDrafts[path] = text
        }
    }

    // NSTextViewDelegate 回调在主线程；协议签名是 nonisolated，这里回到 MainActor。
    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !applyingProgrammaticChange, let text = textView?.string else { return }
            model.fileTabStates[path]?.isDirty = true
            model.editorDrafts[path] = text
            host?.gutter.needsDisplay = true
        }
    }
}
