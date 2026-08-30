import AppKit
import Foundation

extension AppModel {
    func updateWorkspaceBranch() {
        let path = workspacePath
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty, branch != "HEAD" {
                        await MainActor.run { [weak self] in
                            if self?.workspacePath == path {
                                self?.workspaceBranch = branch
                            }
                        }
                        return
                    }
                }
            } catch {}
            await MainActor.run { [weak self] in
                if self?.workspacePath == path {
                    self?.workspaceBranch = nil
                }
            }
        }
    }

    func pickWorkspace() {
        addWorkspace()
    }

    func addWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        panel.message = "选择要加入工作区目录的文件夹"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { WorkspaceRecord.normalized($0.path) }.filter { !$0.isEmpty }
        guard let last = paths.last else { return }
        for path in paths {
            rememberWorkspace(path, used: path == last)
        }
        selectWorkspace(last)
    }

    func selectWorkspace(_ path: String) {
        let normalized = WorkspaceRecord.normalized(path)
        guard !normalized.isEmpty else { return }
        rememberWorkspace(normalized, used: true)
        workspacePath = normalized
        UserDefaults.standard.set(workspacePath, forKey: "workspacePath")
        reloadWorkspaces()
        updateWorkspaceBranch()
        Task { await allowWorkspaceOnRuntimes(normalized) }
    }

    func removeWorkspace(_ path: String) {
        let normalized = WorkspaceRecord.normalized(path)
        if store != nil {
            try? store?.deleteWorkspace(path: normalized)
            reloadWorkspaces()
        } else {
            workspaces.removeAll { $0.path == normalized }
        }
        if workspacePath == normalized {
            if let fallback = workspaces.first?.path {
                selectWorkspace(fallback)
            } else {
                workspacePath = WorkspaceRecord.homePath
                UserDefaults.standard.set(workspacePath, forKey: "workspacePath")
                updateWorkspaceBranch()
            }
        }
    }

    func openWorkspaceInFinder(_ path: String? = nil) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path ?? workspacePath)
    }

    func bootstrapWorkspaces(currentPath: String) {
        dropHomeWorkspace()
        for session in sessions {
            rememberWorkspace(session.cwd, used: false, at: session.createdAt)
        }
        reloadWorkspaces()

        let current = WorkspaceRecord.normalized(currentPath)
        if workspaces.contains(where: { $0.path == current }) {
            return
        }
        if let first = workspaces.first {
            workspacePath = first.path
            UserDefaults.standard.set(workspacePath, forKey: "workspacePath")
        }
    }

    func rememberWorkspace(_ path: String, used: Bool, at date: Date = Date()) {
        let normalized = WorkspaceRecord.normalized(path)
        guard !normalized.isEmpty, !WorkspaceRecord.isHome(normalized) else { return }
        let record = WorkspaceRecord(path: normalized, addedAt: date, lastUsedAt: date)
        if let store {
            try? store.insertWorkspaceIfNeeded(record)
            if used {
                try? store.touchWorkspace(path: normalized, at: date)
            }
            return
        }
        if let index = workspaces.firstIndex(where: { $0.path == normalized }) {
            if used {
                workspaces[index].lastUsedAt = date
                workspaces.sort { $0.lastUsedAt > $1.lastUsedAt }
            }
        } else {
            workspaces.insert(record, at: 0)
        }
    }

    func reloadWorkspaces() {
        if let rows = try? store?.listWorkspaces() {
            workspaces = rows.filter { !WorkspaceRecord.isHome($0.path) }
        }
    }

    private func dropHomeWorkspace() {
        let home = WorkspaceRecord.homePath
        try? store?.deleteWorkspace(path: home)
        workspaces.removeAll { WorkspaceRecord.isHome($0.path) }
    }
}
