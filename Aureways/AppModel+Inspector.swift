import AppKit
import Foundation

struct SessionInspectorState {
    var paneTabs: [PaneTab] = [.browser]
    var activePaneTabId: String = PaneTab.browser.id
    var fileTabStates: [String: FileTabState] = [:]
    var editorDrafts: [String: String] = [:]
}

enum PaneTab: Identifiable, Equatable {
    case browser
    case info
    case file(path: String)
    case terminal(UUID)

    var id: String {
        switch self {
        case .browser: return "browser"
        case .info: return "info"
        case .file(let path): return "file:" + path
        case .terminal(let id): return "term:" + id.uuidString
        }
    }

    var isClosable: Bool {
        self != .browser
    }
}

struct FileTabState {
    var baselineMtime: Date?
    var isDirty = false
    var externallyModified = false
    var reloadToken = 0
    /// Markdown 文件默认预览；其它类型忽略。
    var showsMarkdownPreview = true
}

extension AppModel {
    static let maxEditableFileSize: Int64 = TextFile.maxBytes

    // MARK: - Session-bound inspector

    func persistInspectorState() {
        let snapshot = SessionInspectorState(
            paneTabs: paneTabs,
            activePaneTabId: activePaneTabId,
            fileTabStates: fileTabStates,
            editorDrafts: editorDrafts
        )
        if let inspectorOwner {
            inspectorBySession[inspectorOwner] = snapshot
        } else {
            untitledInspector = snapshot
        }
    }

    func restoreInspectorState(for sessionID: UUID?) {
        inspectorOwner = sessionID
        let snapshot = sessionID.flatMap { inspectorBySession[$0] } ?? (sessionID == nil ? untitledInspector : SessionInspectorState())
        applyInspectorSnapshot(snapshot)
    }

    /// Keep the landing-page tabs when the first message creates a session
    /// in the same folder, instead of resetting the inspector.
    func adoptInspectorForNewSession(_ sessionID: UUID) {
        persistInspectorState()
        inspectorOwner = sessionID
        inspectorBySession[sessionID] = SessionInspectorState(
            paneTabs: paneTabs,
            activePaneTabId: activePaneTabId,
            fileTabStates: fileTabStates,
            editorDrafts: editorDrafts
        )
        untitledInspector = SessionInspectorState()
    }

    func discardInspectorState(_ sessionID: UUID) {
        let snapshot = inspectorBySession.removeValue(forKey: sessionID)
        if inspectorOwner == sessionID {
            inspectorOwner = nil
        }
        guard let snapshot else { return }
        for tab in snapshot.paneTabs {
            if case .terminal(let id) = tab {
                interactiveTerminals[id]?.terminate()
                interactiveTerminals[id] = nil
                terminalTitles[id] = nil
            }
        }
    }

    private func applyInspectorSnapshot(_ snapshot: SessionInspectorState) {
        var tabs = snapshot.paneTabs.filter { tab in
            switch tab {
            case .terminal(let id):
                return interactiveTerminals[id] != nil
            case .file(let path):
                return snapshot.editorDrafts[path] != nil || snapshot.fileTabStates[path] != nil
            case .browser, .info:
                return true
            }
        }
        if !tabs.contains(.browser) {
            tabs.insert(.browser, at: 0)
        }
        paneTabs = tabs
        fileTabStates = snapshot.fileTabStates
        editorDrafts = snapshot.editorDrafts
        activePaneTabId = tabs.contains(where: { $0.id == snapshot.activePaneTabId })
            ? snapshot.activePaneTabId
            : PaneTab.browser.id
    }

    func switchSelectedSession(to newID: UUID?) {
        guard newID != selectedSessionID else { return }
        persistInspectorState()
        selectedSessionID = newID
        restoreInspectorState(for: newID)
        if let cwd = selectedSession?.cwd,
           WorkspaceRecord.normalized(cwd) != WorkspaceRecord.normalized(workspacePath) {
            selectWorkspace(cwd)
        }
    }

    // MARK: - Tab management

    func paneTabTitle(_ tab: PaneTab) -> String {
        switch tab {
        case .browser: return "文件".localized
        case .info: return "信息".localized
        case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .terminal(let id): return terminalTitles[id] ?? "终端".localized
        }
    }

    func selectPaneTab(_ id: String) {
        activePaneTabId = id
    }

    func openInfoTab() {
        if let existing = paneTabs.first(where: { $0 == .info }) {
            activePaneTabId = existing.id
            return
        }
        insertPaneTab(.info)
    }

    func openFileTab(path: String) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let tab = PaneTab.file(path: path)
        if paneTabs.contains(where: { $0.id == tab.id }) {
            activePaneTabId = tab.id
            inspectorOpen = true
            return
        }
        guard ensureFileLoaded(path: path) else { return }
        insertPaneTab(tab)
    }

    /// Persist an oversize composer paste as a workspace draft so the inspector
    /// can edit it and the composer can render a card. Send still reads the
    /// file and emits a `text` content block.
    func capturePastedText(_ text: String) -> ComposerAttachment? {
        do {
            let url = try ComposerOverflow.write(text, inWorkspace: inspectorRoot)
            return ComposerOverflow.pastedAttachment(
                url: url,
                characterCount: ComposerOverflow.utf16Count(text)
            )
        } catch ComposerOverflow.WriteError.tooLarge {
            errorMessage = "粘贴内容超过 2MB，暂不支持在编辑器中打开".localized
            return nil
        } catch {
            errorMessage = "无法保存粘贴的文本".localized
            return nil
        }
    }

    /// Write dirty pasted-text drafts to disk before send so the text block
    /// carries the inspector buffer, not the file as it was at paste time.
    @discardableResult
    func flushPastedTextAttachments(_ attachments: [ComposerAttachment]) -> Bool {
        for attachment in attachments where attachment.kind == .pastedText {
            guard let path = attachment.url?.standardizedFileURL.path,
                  fileTabStates[path]?.isDirty == true,
                  let content = editorDrafts[path] else { continue }
            writeFileTab(path: path, content: content)
            if errorMessage != nil { return false }
        }
        return true
    }

    func discardPastedTextDraft(_ attachment: ComposerAttachment) {
        guard attachment.kind == .pastedText, let path = attachment.url?.standardizedFileURL.path else { return }
        if paneTabs.contains(where: { $0.id == PaneTab.file(path: path).id }) {
            performClosePaneTab(.file(path: path))
        }
        if ComposerOverflow.isPastePath(path) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    @discardableResult
    func ensureFileLoaded(path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if fileTabStates[path] != nil { return true }
        let url = URL(fileURLWithPath: path)
        do {
            let text = try TextFile.read(from: url, maxBytes: Self.maxEditableFileSize)
            var state = FileTabState()
            state.baselineMtime = modificationDate(of: url)
            fileTabStates[path] = state
            editorDrafts[path] = text
            return true
        } catch TextFile.ReadError.tooLarge {
            errorMessage = "文件超过 2MB，暂不支持打开".localized
        } catch TextFile.ReadError.binaryOrNotUTF8 {
            errorMessage = "无法打开：仅支持 UTF-8 文本文件".localized
        } catch {
            errorMessage = "无法打开文件：%@".localized(url.lastPathComponent)
        }
        return false
    }

    func openMarkdownDocuments(urls: [URL]) {
        let markdown = urls.filter { MarkdownFile.matches(url: $0) }
        if markdown.isEmpty {
            if !urls.isEmpty {
                errorMessage = "不是 Markdown 文件".localized
            }
            return
        }
        for url in markdown {
            openFileTab(path: url.standardizedFileURL.path)
        }
    }

    func pickAndOpenMarkdownDocuments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MarkdownFile.contentTypes
        panel.message = "选择 Markdown 文件".localized
        panel.prompt = "打开".localized
        guard panel.runModal() == .OK else { return }
        AppActivation.revealMainWindow()
        openMarkdownDocuments(urls: panel.urls)
    }

    func openTerminalTab() {
        let terminal = InteractiveTerminal(index: nextTerminalIndex, cwd: inspectorRoot)
        interactiveTerminals[terminal.id] = terminal
        terminalTitles[terminal.id] = terminal.title
        terminal.onExited = { [weak self, weak terminal] _ in
            guard let self, let terminal else { return }
            // 用户在 PTY 里敲 `exit` 后进程已结束；关掉标签才能释放视图、PTY 和下标。
            self.performClosePaneTab(.terminal(terminal.id))
        }
        terminal.start()
        insertPaneTab(.terminal(terminal.id))
    }

    func closePaneTab(_ tab: PaneTab) {
        guard tab.isClosable else { return }
        if case .file(let path) = tab, fileTabStates[path]?.isDirty == true {
            pendingClosePath = path
            return
        }
        performClosePaneTab(tab)
    }

    func performClosePaneTab(_ tab: PaneTab) {
        switch tab {
        case .terminal(let id):
            interactiveTerminals[id]?.terminate()
            interactiveTerminals[id] = nil
            terminalTitles[id] = nil
        case .file(let path):
            fileTabStates[path] = nil
            editorDrafts[path] = nil
        default:
            break
        }
        paneTabs.removeAll { $0.id == tab.id }
        if activePaneTabId == tab.id {
            activePaneTabId = paneTabs.last?.id ?? PaneTab.browser.id
        }
    }

    func closeOtherPaneTabs(keeping tab: PaneTab) {
        for other in paneTabs where other.id != tab.id && other.isClosable {
            closePaneTab(other)
            if pendingClosePath != nil { break }
        }
    }

    func resolvePendingCloseFileTab(save: Bool) {
        guard let path = pendingClosePath else { return }
        pendingClosePath = nil
        if save, let content = editorDrafts[path] {
            saveFileTab(path: path, content: content)
        }
        performClosePaneTab(.file(path: path))
    }

    func terminateAllTerminals() {
        for terminal in interactiveTerminals.values {
            terminal.terminate()
        }
        interactiveTerminals.removeAll()
        terminalTitles.removeAll()
    }

    private var nextTerminalIndex: Int {
        let used = Set(interactiveTerminals.values.map(\.index))
        var index = 1
        while used.contains(index) { index += 1 }
        return index
    }

    private func insertPaneTab(_ tab: PaneTab) {
        paneTabs.append(tab)
        activePaneTabId = tab.id
        inspectorOpen = true
    }

    // MARK: - File editing

    func saveFileTab(path: String, content: String) {
        let url = URL(fileURLWithPath: path)
        if let disk = modificationDate(of: url),
           let baseline = fileTabStates[path]?.baselineMtime,
           abs(disk.timeIntervalSince(baseline)) > 0.001 {
            pendingSavePath = path
            pendingSaveContent = content
            return
        }
        writeFileTab(path: path, content: content)
    }

    func writeFileTab(path: String, content: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            fileTabStates[path]?.baselineMtime = modificationDate(of: url)
            fileTabStates[path]?.isDirty = false
            fileTabStates[path]?.externallyModified = false
            pendingSavePath = nil
            pendingSaveContent = nil
        } catch {
            errorMessage = "保存失败：%@".localized(error.localizedDescription)
        }
    }

    func cancelPendingSave() {
        pendingSavePath = nil
        pendingSaveContent = nil
    }

    func requestReloadFileTab(_ path: String) {
        if fileTabStates[path]?.isDirty == true {
            pendingReloadPath = path
        } else {
            reloadFileTab(path)
        }
    }

    func confirmPendingReload() {
        guard let path = pendingReloadPath else { return }
        pendingReloadPath = nil
        reloadFileTab(path)
    }

    func reloadFileTab(_ path: String) {
        guard var state = fileTabStates[path] else { return }
        let url = URL(fileURLWithPath: path)
        state.baselineMtime = modificationDate(of: url)
        state.externallyModified = false
        state.isDirty = false
        state.reloadToken += 1
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            editorDrafts[path] = text
        }
        fileTabStates[path] = state
    }

    func keepEditedFileTab(_ path: String) {
        // 把当前磁盘内容当作新基线，保留编辑器里未保存的修改。
        fileTabStates[path]?.baselineMtime = modificationDate(of: URL(fileURLWithPath: path))
        fileTabStates[path]?.externallyModified = false
    }

    // MARK: - Agent-driven file changes

    func agentWroteFile(_ rawPath: String) {
        browserInvalidationToken += 1
        let path = normalizeWorkspacePath(rawPath)
        guard fileTabStates[path] != nil else { return }
        if fileTabStates[path]?.isDirty == true {
            fileTabStates[path]?.externallyModified = true
        } else {
            reloadFileTab(path)
        }
    }

    func normalizeWorkspacePath(_ path: String) -> String {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: inspectorRoot, isDirectory: true)).standardizedFileURL.path
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
