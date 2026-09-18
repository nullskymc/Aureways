import AppKit
import SwiftUI
import XCTest

/// 宿主进程内验证 ComposerTextView 的 TextKit 装配、聚焦与输入链路。
/// 背景：子类曾覆写 designated 构造器导致 textStorage 恒为 nil、输入全部 no-op，
/// 这里的断言锁定该回归。
@MainActor
final class ComposerTextViewTests: XCTestCase {

    private final class Box {
        var draft = ""
        var focused = false
        var attachments: [[ComposerAttachment]] = []
        var commands: [ComposerCommand] = []
        var overflowTexts: [String] = []
        var pasteTooLargeCount = 0
        weak var coordinator: ComposerCoordinator?
    }

    private struct HostView: View {
        let box: Box
        var body: some View {
            ComposerTextRepresentable(
                draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                isFocused: Binding(get: { box.focused }, set: { box.focused = $0 }),
                onAttachments: { box.attachments.append($0) },
                onOverflowText: { box.overflowTexts.append($0) },
                onPasteTooLarge: { box.pasteTooLargeCount += 1 },
                onCommand: { command in
                    box.commands.append(command)
                    return true
                },
                coordinatorSink: { box.coordinator = $0 }
            )
            .frame(width: 300, height: 44)
        }
    }

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private struct HostNotFoundError: Error {}

    private func makeHostedTextView() throws -> (ComposerTextView, Box) {
        let box = Box()
        let host = NSHostingView(rootView: HostView(box: box))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        drainRunloop()

        var found: ComposerTextView?
        find(view: host) { found = $0 }
        guard let textView = found else { throw HostNotFoundError() }
        return (textView, box)
    }

    private func find(view: NSView, handler: (ComposerTextView) -> Void) {
        if let composerView = view as? ComposerTextView {
            handler(composerView)
        }
        for subview in view.subviews {
            find(view: subview, handler: handler)
        }
    }

    private func drainRunloop() {
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testTextViewAssemblesTextKitStack() throws {
        let (textView, _) = try makeHostedTextView()
        XCTAssertTrue(textView.isEditable)
        XCTAssertNotNil(textView.textContainer, "构造路径不得绕开 NSTextView 默认 TextKit 装配")
        XCTAssertNotNil(textView.textStorage)
    }

    func testTypingUpdatesDraft() throws {
        let (textView, box) = try makeHostedTextView()
        XCTAssertTrue(window.makeFirstResponder(textView), "textView 应能成为第一响应者")

        textView.insertText("你好")
        drainRunloop()
        XCTAssertEqual(textView.string, "你好")
        XCTAssertEqual(box.draft, "你好", "textDidChange 应回传 draft binding")

        textView.insertText(" world")
        drainRunloop()
        XCTAssertEqual(box.draft, "你好 world", "连续输入应持续同步")
    }

    func testDoCommandByReportsConfirm() throws {
        let (textView, box) = try makeHostedTextView()
        window.makeFirstResponder(textView)
        textView.insertText("hello")
        drainRunloop()
        box.commands = []

        let handled = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) as? Bool
        XCTAssertEqual(handled, true, "弹层关闭时 Return 应上报 confirm 且被消费")
        XCTAssertEqual(box.commands, [.confirm])
        XCTAssertEqual(box.draft, "hello", "confirm 未命中弹层时不应改动文本")
    }

    func testCoordinatorSetDraftWritesTextView() throws {
        let (textView, box) = try makeHostedTextView()
        try XCTUnwrap(box.coordinator).setDraft("/help ")
        XCTAssertEqual(textView.string, "/help ")
        XCTAssertEqual(box.draft, "/help ")
        XCTAssertEqual(textView.selectedRange().location, 6, "光标应落在末尾")
    }

    func testPasteImageBecomesAttachment() throws {
        let (textView, box) = try makeHostedTextView()
        window.makeFirstResponder(textView)

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: NSSize(width: 8, height: 8)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        defer { pasteboard.clearContents() }

        textView.paste(nil)
        drainRunloop()

        XCTAssertEqual(box.attachments.count, 1, "粘贴 TIFF 应产出一个图片附件")
        XCTAssertEqual(box.attachments.first?.first?.kind, .image)
        XCTAssertEqual(box.attachments.first?.first?.mimeType, "image/png")
    }

    private func commandVEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
    }

    func testCmdVIsIgnoredWhenComposerIsNotFirstResponder() throws {
        let (textView, box) = try makeHostedTextView()
        XCTAssertTrue(window.makeFirstResponder(nil) || window.firstResponder !== textView)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("stolen", forType: .string)
        defer { pasteboard.clearContents() }

        let handled = textView.performKeyEquivalent(with: try commandVEvent())
        drainRunloop()

        XCTAssertFalse(handled, "未聚焦时不得把 ⌘V 当成输入框粘贴")
        XCTAssertEqual(textView.string, "")
        XCTAssertTrue(box.attachments.isEmpty)
    }

    func testCmdVPastesWhenComposerIsFirstResponder() throws {
        let (textView, _) = try makeHostedTextView()
        XCTAssertTrue(window.makeFirstResponder(textView))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("from clipboard", forType: .string)
        defer { pasteboard.clearContents() }

        let handled = textView.performKeyEquivalent(with: try commandVEvent())
        drainRunloop()

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "from clipboard")
    }

    func testPasteTextStillInserts() throws {
        let (textView, box) = try makeHostedTextView()
        window.makeFirstResponder(textView)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        defer { pasteboard.clearContents() }

        textView.paste(nil)
        drainRunloop()

        XCTAssertEqual(textView.string, "plain text", "纯文本粘贴应走系统默认路径")
        XCTAssertEqual(box.draft, "plain text")
        XCTAssertTrue(box.attachments.isEmpty)
        XCTAssertTrue(box.overflowTexts.isEmpty)
    }

    func testOverflowThresholdAndWorkspaceDraft() throws {
        XCTAssertFalse(ComposerOverflow.exceedsInlineLimit(String(repeating: "a", count: ComposerOverflow.inlineUTF16Limit)))
        XCTAssertTrue(ComposerOverflow.exceedsInlineLimit(String(repeating: "a", count: ComposerOverflow.inlineUTF16Limit + 1)))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aureways-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = String(repeating: "字", count: ComposerOverflow.inlineUTF16Limit + 10)
        let url = try ComposerOverflow.write(text, inWorkspace: root.path)
        XCTAssertTrue(ComposerOverflow.isPastePath(url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)

        let attachment = ComposerOverflow.pastedAttachment(url: url, characterCount: ComposerOverflow.utf16Count(text))
        XCTAssertEqual(attachment.kind, .pastedText)
        XCTAssertEqual(attachment.transcriptAttachment.kind, "file")
        XCTAssertEqual(attachment.transcriptAttachment.path, url.path)
        XCTAssertEqual(attachment.transcriptAttachment.mimeType, "text/plain")

        let tooLarge = String(repeating: "a", count: ComposerOverflow.maxBytes + 1)
        XCTAssertThrowsError(try ComposerOverflow.write(tooLarge, inWorkspace: root.path)) { error in
            XCTAssertEqual(error as? ComposerOverflow.WriteError, .tooLarge)
        }
    }

    func testPasteOverflowDoesNotEnterTextView() throws {
        let (textView, box) = try makeHostedTextView()
        window.makeFirstResponder(textView)
        textView.insertText("keep")
        drainRunloop()
        XCTAssertEqual(box.draft, "keep")

        let overflow = String(repeating: "x", count: ComposerOverflow.inlineUTF16Limit + 25)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(overflow, forType: .string)
        defer { pasteboard.clearContents() }

        textView.paste(nil)
        drainRunloop()

        XCTAssertEqual(textView.string, "keep", "超长粘贴不得写入 NSTextView")
        XCTAssertEqual(box.draft, "keep")
        XCTAssertEqual(box.overflowTexts, [overflow])
        XCTAssertTrue(box.attachments.isEmpty)
        XCTAssertEqual(box.pasteTooLargeCount, 0)
    }

    func testClassifyTextTooLarge() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "a", count: ComposerOverflow.maxBytes + 1), forType: .string)
        defer { pasteboard.clearContents() }
        XCTAssertEqual(ComposerOverflow.classifyText(on: pasteboard), .tooLarge)
    }

    func testPasteImageFileURLBecomesAttachment() throws {
        let (textView, box) = try makeHostedTextView()
        window.makeFirstResponder(textView)

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: NSSize(width: 8, height: 8)).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(image.tiffRepresentation).let { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString).png")
        try XCTUnwrap(png).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        defer { pasteboard.clearContents() }

        textView.paste(nil)
        drainRunloop()

        XCTAssertEqual(box.attachments.count, 1, "粘贴图片文件 URL 应产出图片附件")
        XCTAssertEqual(box.attachments.first?.first?.kind, .image)
        XCTAssertEqual(box.attachments.first?.first?.name, url.lastPathComponent)
    }

    // MARK: - 真实 SwiftUI 状态桥接（@State + Binding + onChange + coordinatorSink 同构复刻）

    /// 复刻 ComposerCard 的关键结构（修复后的桥模式）：@State draft、桥对象存
    /// coordinator、onChange 驱动补全状态机。历史上 makeNSView 期间直接写
    /// @State 会被 SwiftUI 丢弃导致补全失灵，此测试锁定桥模式可用。
    private final class MiniCardProbe: ObservableObject {
        @Published var mode = "none"
        @Published var attachmentCount = 0
        @Published var submittedText: String?
    }

    private struct MiniComposerCard: View {
        @ObservedObject var probe: MiniCardProbe
        @State private var draft = ""
        @State private var editor = ComposerEditorBridge()
        @FocusState private var focused: Bool

        var body: some View {
            ComposerTextRepresentable(
                draft: $draft,
                isFocused: Binding(get: { focused }, set: { focused = $0 }),
                onAttachments: { _ in probe.attachmentCount += 1 },
                onCommand: { command in
                    if case .confirm = command {
                        probe.submittedText = draft
                        return true
                    }
                    return false
                },
                coordinatorSink: { editor.coordinator = $0 }
            )
            .frame(width: 300, height: 44)
            .onChange(of: draft) { updateMode() }
        }

        private func updateMode() {
            guard let textView = editor.coordinator?.textView, !textView.hasMarkedText() else {
                probe.mode = "none"
                return
            }
            let cursor = textView.selectedRange().location
            let ns = draft as NSString
            let before = ns.substring(to: min(cursor, ns.length))
            if before.hasPrefix("/"), !before.contains("\n") {
                probe.mode = "slash"
            } else if before.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\n" }).last?.hasPrefix("@") == true {
                probe.mode = "mention"
            } else {
                probe.mode = "none"
            }
        }
    }

    func testMiniCardStateBridgeDrivesCompletionMode() throws {
        let probe = MiniCardProbe()
        let host = NSHostingView(rootView: MiniComposerCard(probe: probe))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        drainRunloop()

        var found: ComposerTextView?
        find(view: host) { found = $0 }
        let textView = try XCTUnwrap(found)
        window.makeFirstResponder(textView)

        textView.insertText("/")
        drainRunloop()
        XCTAssertEqual(probe.mode, "slash", "输入 / 应驱动补全模式（@State+Binding+onChange 桥接）")

        textView.insertText("he")
        drainRunloop()
        XCTAssertEqual(probe.mode, "slash")
        XCTAssertEqual(textView.string, "/he")

        textView.string = ""
        drainRunloop()
        textView.insertText("看看 @Compo")
        drainRunloop()
        XCTAssertEqual(probe.mode, "mention", "输入 @xxx 应驱动 mention 模式")

        textView.string = ""
        drainRunloop()
        textView.insertText("普通文本")
        drainRunloop()
        XCTAssertEqual(probe.mode, "none")
    }

    func testMiniCardPasteUpdatesAttachmentState() throws {
        let probe = MiniCardProbe()
        let host = NSHostingView(rootView: MiniComposerCard(probe: probe))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        drainRunloop()

        var found: ComposerTextView?
        find(view: host) { found = $0 }
        let textView = try XCTUnwrap(found)
        window.makeFirstResponder(textView)

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(origin: .zero, size: NSSize(width: 8, height: 8)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        defer { pasteboard.clearContents() }

        textView.paste(nil)
        drainRunloop()
        XCTAssertEqual(probe.attachmentCount, 1, "粘贴图片应经 onAttachments 更新 @State")
    }
}

private extension Optional {
    func `let`<R>(_ transform: (Wrapped) -> R?) -> R? {
        switch self {
        case .some(let wrapped): return transform(wrapped)
        case .none: return nil
        }
    }
}
