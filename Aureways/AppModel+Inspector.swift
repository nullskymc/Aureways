import AppKit
import Foundation

/// File-related model helpers. The inspector UI itself (tabs, buffers,
/// terminals) lives in the web app; see WebShellServices.swift.
extension AppModel {
    func switchSelectedSession(to newID: UUID?) {
        guard newID != selectedSessionID else { return }
        selectedSessionID = newID
        if let cwd = selectedSession?.cwd,
           WorkspaceRecord.normalized(cwd) != WorkspaceRecord.normalized(workspacePath) {
            selectWorkspace(cwd)
        }
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

    func discardPastedTextDraft(_ attachment: ComposerAttachment) {
        guard attachment.kind == .pastedText, let path = attachment.url?.standardizedFileURL.path else { return }
        if ComposerOverflow.isPastePath(path) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    /// Finder "Open With", ⌘O and drops: Markdown files open in the web inspector.
    func openMarkdownDocuments(urls: [URL]) {
        let markdown = urls.filter { MarkdownFile.matches(url: $0) }
        if markdown.isEmpty {
            if !urls.isEmpty {
                errorMessage = "不是 Markdown 文件".localized
            }
            return
        }
        WebShellBridge.current?.openFiles(markdown.map { $0.standardizedFileURL.path })
    }

    // MARK: - Agent-driven file changes

    func agentWroteFile(_ rawPath: String) {
        WebShellBridge.current?.notifyFileChanged(normalizeWorkspacePath(rawPath))
    }

    func normalizeWorkspacePath(_ path: String) -> String {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: inspectorRoot, isDirectory: true)).standardizedFileURL.path
    }
}
