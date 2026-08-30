import AppKit
import SwiftUI

// MARK: - File Editor Tab

struct FileEditorTabView: View {
    @Environment(AppModel.self) private var model
    let path: String

    private var state: FileTabState? { model.fileTabStates[path] }

    var body: some View {
        VStack(spacing: 0) {
            if state?.externallyModified == true {
                externalChangeBanner
                Divider()
            }

            TextEditorRepresentable(path: path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            statusBar
        }
    }

    private var externalChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.gold)
            Text("文件已被 Agent 修改")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("重载") {
                model.reloadFileTab(path)
            }
            .font(.system(size: 11))
            Button("保留我的") {
                model.keepEditedFileTab(path)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if state?.isDirty == true {
                Text("未保存 ⌘S")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.gold)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - NSTextView wrapper

private final class LineNumberRulerView: NSRulerView {
    weak var clientTextView: NSTextView?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 34
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let visibleRect = scrollView.documentVisibleRect
        let containerOrigin = textView.textContainerOrigin
        let boundingRect = visibleRect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: boundingRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString

        // 首个可见行之前有多少行，作为行号起点；一次遍历，之后逐行推进。
        var lineNumber = 1
        if charRange.location > 0 {
            lineNumber += (string.substring(to: charRange.location) as NSString).components(separatedBy: "\n").count - 1
        }

        var index = charRange.location
        while index < NSMaxRange(charRange) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil).location
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + containerOrigin.y - visibleRect.minY
            if y + lineRect.height >= 0, y <= visibleRect.height {
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(
                    at: NSPoint(x: bounds.maxX - size.width - 8, y: y + (lineRect.height - size.height) / 2),
                    withAttributes: attrs
                )
            }
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
    }
}

private final class SaveTextView: NSTextView {
    var saveHandler: (() -> Void)?

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

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, path: path)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

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
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: scrollView.contentSize.height)

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientTextView = textView
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.loadFromDisk()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.syncReload()
    }
}

@MainActor
private final class Coordinator: NSObject, NSTextViewDelegate {
    var model: AppModel
    let path: String
    weak var textView: SaveTextView?
    weak var ruler: LineNumberRulerView?
    private var loadedReloadToken = 0
    private var applyingProgrammaticChange = false

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
    }

    func loadFromDisk() {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            apply(text)
        } else {
            applyingProgrammaticChange = true
            textView?.string = "（无法读取文件内容）"
            textView?.isEditable = false
            applyingProgrammaticChange = false
            ruler?.needsDisplay = true
        }
        loadedReloadToken = model.fileTabStates[path]?.reloadToken ?? 0
    }

    func syncReload() {
        let token = model.fileTabStates[path]?.reloadToken ?? 0
        guard token != loadedReloadToken else { return }
        loadFromDisk()
    }

    func save() {
        guard let text = textView?.string else { return }
        model.saveFileTab(path: path, content: text)
    }

    private func apply(_ text: String) {
        applyingProgrammaticChange = true
        textView?.string = text
        applyingProgrammaticChange = false
        ruler?.needsDisplay = true
        model.editorDrafts[path] = text
    }

    // NSTextViewDelegate 回调在主线程；协议签名是 nonisolated，这里回到 MainActor。
    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !applyingProgrammaticChange, let text = textView?.string else { return }
            model.fileTabStates[path]?.isDirty = true
            model.editorDrafts[path] = text
            ruler?.needsDisplay = true
        }
    }
}
