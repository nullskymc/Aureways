import Foundation

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

    var icon: String {
        switch self {
        case .browser: return "folder"
        case .info: return "info.circle"
        case .file: return "doc.text"
        case .terminal: return "terminal"
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
}

extension AppModel {
    static let maxEditableFileSize: Int64 = 2 * 1024 * 1024

    // MARK: - Tab management

    func paneTabTitle(_ tab: PaneTab) -> String {
        switch tab {
        case .browser: return "文件"
        case .info: return "信息"
        case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .terminal(let id): return terminalTitles[id] ?? "终端"
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
        let tab = PaneTab.file(path: path)
        if paneTabs.contains(where: { $0.id == tab.id }) {
            activePaneTabId = tab.id
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            errorMessage = "无法打开文件：\(url.lastPathComponent)"
            return
        }
        guard size <= Self.maxEditableFileSize else {
            errorMessage = "文件超过 2MB，暂不支持打开"
            return
        }
        guard let data = try? Data(contentsOf: url), !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            errorMessage = "无法打开：仅支持 UTF-8 文本文件"
            return
        }
        var state = FileTabState()
        state.baselineMtime = modificationDate(of: url)
        fileTabStates[path] = state
        insertPaneTab(tab)
    }

    func openTerminalTab() {
        let terminal = InteractiveTerminal(index: nextTerminalIndex, cwd: workspacePath)
        interactiveTerminals[terminal.id] = terminal
        terminalTitles[terminal.id] = terminal.title
        terminal.onExited = { [weak self, weak terminal] _ in
            guard let self, let terminal else { return }
            self.terminalTitles[terminal.id] = terminal.title
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
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func cancelPendingSave() {
        pendingSavePath = nil
        pendingSaveContent = nil
    }

    func reloadFileTab(_ path: String) {
        guard var state = fileTabStates[path] else { return }
        state.baselineMtime = modificationDate(of: URL(fileURLWithPath: path))
        state.externallyModified = false
        state.isDirty = false
        state.reloadToken += 1
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
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true)).standardizedFileURL.path
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
