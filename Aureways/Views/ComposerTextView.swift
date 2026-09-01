import AppKit
import SwiftUI

/// 弹层与提交的键盘指令，由 NSTextView 的 doCommandBy 上报给 ComposerCard，
/// 返回 true 表示已消费、不再走文本视图默认行为。
enum ComposerCommand {
    case moveUp
    case moveDown
    case confirm
    case tab
    case cancel
}

final class ComposerTextView: NSTextView {
    var attachmentHandler: (([ComposerAttachment]) -> Void)?

    // 不覆写任何构造器（与文件编辑器的 SaveTextView 一致）：覆写 designated
    // init(frame:textContainer:) 后经它创建会绕开 NSTextView 默认 TextKit 装配，
    // textStorage 恒为 nil，键入与 string 直写全部 no-op（回归测试锁定）。
    private var didRegisterDragTypes = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard !didRegisterDragTypes, newWindow != nil else { return }
        didRegisterDragTypes = true
        // 只追加类型不减 acceptableDragTypes，应用内拖选文本仍走 NSTextView 默认插入。
        registerForDraggedTypes(acceptableDragTypes + [.fileURL, .tiff, .png])
    }

    // ⌘V 不依赖主菜单派发（保险层，模式与文件编辑器的 ⌘S 拦截一致）；
    // paste: 内部自行分流图片/文件/文本。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // ⌘V：剪贴板有图片/文件时转附件，否则走系统文本粘贴。
    override func paste(_ sender: Any?) {
        let attachments = ComposerAttachment.fromPasteboard(.general)
        if !attachments.isEmpty {
            attachmentHandler?(attachments)
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasAttachmentContent(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let attachments = ComposerAttachment.fromFileURLs(urls)
            if !attachments.isEmpty {
                attachmentHandler?(attachments)
                return true
            }
            return super.performDragOperation(sender)
        }
        if hasAttachmentContent(pasteboard) {
            let attachments = ComposerAttachment.fromPasteboard(pasteboard)
            if !attachments.isEmpty {
                attachmentHandler?(attachments)
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    private func hasAttachmentContent(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
    }
}

struct ComposerTextRepresentable: NSViewRepresentable {
    @Binding var draft: String
    @Binding var isFocused: Bool
    let onAttachments: ([ComposerAttachment]) -> Void
    let onCommand: (ComposerCommand) -> Bool
    let coordinatorSink: (ComposerCoordinator) -> Void

    func makeCoordinator() -> ComposerCoordinator {
        ComposerCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 13.5)
        textView.drawsBackground = false
        // 与隐藏镜像 Text 左缘对齐：去掉 NSTextView 自带的行内边距，
        // 替代原 TextEditor 方案的 .padding(.leading, -5) 技巧。
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.parent = self
        textView.attachmentHandler = { [weak coordinator = context.coordinator] attachments in
            guard let coordinator else { return }
            coordinator.parent.onAttachments(attachments)
        }
        coordinatorSink(context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // IME 组词期间 textView.string 含未上屏的 marked text，与 draft 必然不一致，回写会打断组词。
        if !textView.hasMarkedText(), textView.string != draft {
            context.coordinator.setDraft(draft)
        }
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }
}

/// ComposerCard 经 @State 持有的编辑器桥。makeNSView 期间直接给 @State 赋值
/// 会被 SwiftUI 丢弃（实测 coordinator 读回 nil，补全状态机失灵）；
/// @State 只存这个 class 实例，makeNSView 改其属性即可安全存活。
@MainActor
final class ComposerEditorBridge {
    weak var coordinator: ComposerCoordinator?
}

@MainActor
final class ComposerCoordinator: NSObject, NSTextViewDelegate {
    fileprivate var parent: ComposerTextRepresentable
    weak var textView: ComposerTextView?
    private var applyingProgrammaticChange = false

    init(parent: ComposerTextRepresentable) {
        self.parent = parent
    }

    /// 编程改全文（斜杠命令替换、提交后清空），写回 draft 并把光标落末尾。
    func setDraft(_ text: String) {
        guard let textView else { return }
        applyingProgrammaticChange = true
        textView.string = text
        parent.draft = text
        applyingProgrammaticChange = false
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// 在指定范围插入文本（@补全确认用），textDidChange 不再重复写 draft。
    func insert(_ text: String, replacing range: NSRange) {
        guard let textView else { return }
        applyingProgrammaticChange = true
        textView.insertText(text, replacementRange: range)
        parent.draft = textView.string
        applyingProgrammaticChange = false
    }

    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !applyingProgrammaticChange, let textView else { return }
            parent.draft = textView.string
        }
    }

    nonisolated func textViewDidBeginEditing(_ notification: Notification) {
        MainActor.assumeIsolated { parent.isFocused = true }
    }

    nonisolated func textViewDidEndEditing(_ notification: Notification) {
        MainActor.assumeIsolated { parent.isFocused = false }
    }

    nonisolated func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // IME 确认候选的 Return 由输入管理器先消费；这里再兜一层。
                if textView.hasMarkedText() { return false }
                // Shift+Return / ⌘Return 等修饰组合保留旧行为：换行或交给按钮快捷键。
                if let event = NSApp.currentEvent, event.type == .keyDown,
                   !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    return false
                }
                return parent.onCommand(.confirm)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.moveUp)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.moveDown)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCommand(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.cancel)
            case #selector(NSResponder.complete(_:)):
                // NSTextView 把 Esc 绑到 complete:（补全面板）；弹层开着时优先当作关闭弹层。
                return parent.onCommand(.cancel)
            default:
                return false
            }
        }
    }
}
