import AppKit
import SwiftUI

/// Finder / ⌘O 打开的 Markdown 窗口。独立于 `AppModel`：不进工作台草稿、
/// 不观察会话流式更新，也不去抢 SwiftUI 的 `NSWindow.delegate`。
struct MarkdownDocumentView: View {
    @State private var document: MarkdownDocumentState
    @Environment(\.colorScheme) private var colorScheme

    init(path: String) {
        _document = State(initialValue: MarkdownDocumentState(path: path))
    }

    var body: some View {
        @Bindable var document = document
        VStack(spacing: 0) {
            MarkdownDocumentHeader(document: document)
                .frame(minHeight: 32)
                .fixedSize(horizontal: false, vertical: true)
                .background(Palette.inspectorBg)

            Divider()
                .overlay(Palette.splitDivider)

            Group {
                if let loadError = document.loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(Palette.gold)
                        Text(loadError)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                } else if document.showsPreview {
                    preview
                } else {
                    TextEditor(text: $document.text)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: document.text) { _, _ in
                            document.markEdited()
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .overlay(Palette.splitDivider)

            MarkdownDocumentStatusBar(document: document)
                .fixedSize(horizontal: false, vertical: true)
                .background(Palette.inspectorBg)
        }
        .background(Palette.inspectorBg)
        .background { saveShortcut }
        .background {
            WindowRepresentedFile(path: document.path, isEdited: document.isDirty)
        }
        .liquidGlassWindow(appearance: colorScheme)
        .navigationTitle(document.isDirty ? "● \(document.fileName)" : document.fileName)
        .navigationDocument(URL(fileURLWithPath: document.path))
        .onAppear { document.loadIfNeeded() }
    }

    private var preview: some View {
        ScrollView {
            MarkdownBody(source: document.text, isStreaming: false)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var saveShortcut: some View {
        Button("") { document.save() }
            .keyboardShortcut("s", modifiers: [.command])
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@Observable
@MainActor
final class MarkdownDocumentState {
    let path: String
    var text = ""
    var showsPreview = true
    var isDirty = false
    var loadError: String?
    private var didLoad = false
    private var applyingLoad = false

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    init(path: String) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        reload()
    }

    func reload() {
        applyingLoad = true
        let url = URL(fileURLWithPath: path)
        do {
            text = try TextFile.read(from: url)
            isDirty = false
            loadError = nil
            didLoad = true
        } catch TextFile.ReadError.tooLarge {
            loadError = "文件超过 2MB，暂不支持打开".localized
            didLoad = true
        } catch TextFile.ReadError.binaryOrNotUTF8 {
            loadError = "无法打开：仅支持 UTF-8 文本文件".localized
            didLoad = true
        } catch {
            loadError = "无法打开文件：%@".localized(fileName)
            didLoad = true
        }
        applyingLoad = false
    }

    func markEdited() {
        guard !applyingLoad, !isDirty else { return }
        isDirty = true
    }

    func save() {
        let url = URL(fileURLWithPath: path)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            loadError = nil
        } catch {
            loadError = "保存失败：%@".localized(error.localizedDescription)
        }
    }
}

private struct MarkdownDocumentHeader: View {
    @Bindable var document: MarkdownDocumentState
    @State private var isCopyHovered = false
    @State private var isFinderHovered = false
    @State private var isReloadHovered = false
    @State private var copiedFeedback = false

    private var visual: FileVisual { FileVisual.for(path: document.path) }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: visual.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(visual.color)
                Text(document.fileName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if document.isDirty {
                    Circle()
                        .fill(Palette.gold)
                        .frame(width: 5, height: 5)
                        .help("未保存".localized)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 1) {
                MarkdownModeSwitcher(showsPreview: document.showsPreview) { preview in
                    document.showsPreview = preview
                }
                .padding(.trailing, 5)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.path, forType: .string)
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
                .help(copiedFeedback ? "已复制路径".localized : "复制完整路径".localized)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)])
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
                .help("在 Finder 中显示".localized)

                Button {
                    document.reload()
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
                .help("重新从磁盘载入".localized)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct MarkdownDocumentStatusBar: View {
    let document: MarkdownDocumentState
    private var visual: FileVisual { FileVisual.for(path: document.path) }

    private var lineCount: Int {
        guard !document.text.isEmpty else { return 0 }
        var count = 1
        for byte in document.text.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(visual.color)
                    .frame(width: 6, height: 6)
                Text(visual.language)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            Text("·").foregroundStyle(.tertiary)
            Text("共 %lld 行".localized(lineCount))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(document.showsPreview ? "预览".localized : "UTF-8")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if document.isDirty {
                Text("⌘S 保存".localized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.gold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.gold.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// 只写代理图标和「已编辑」点，不替换 SwiftUI 的 window.delegate。
private struct WindowRepresentedFile: NSViewRepresentable {
    let path: String
    var isEdited: Bool

    func makeNSView(context: Context) -> RepresentedFileProbe {
        let view = RepresentedFileProbe()
        view.filePath = path
        view.isEdited = isEdited
        return view
    }

    func updateNSView(_ nsView: RepresentedFileProbe, context: Context) {
        nsView.filePath = path
        nsView.isEdited = isEdited
        nsView.apply()
    }
}

private final class RepresentedFileProbe: NSView {
    var filePath = ""
    var isEdited = false

    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window else { return }
        if window.representedFilename != filePath {
            window.representedFilename = filePath
        }
        if window.isDocumentEdited != isEdited {
            window.isDocumentEdited = isEdited
        }
    }
}
