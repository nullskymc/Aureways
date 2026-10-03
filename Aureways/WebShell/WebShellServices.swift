import AppKit
import Foundation
import UniformTypeIdentifiers

/// Request/response calls from the web app (`{type:"rpc", id, method, params}`
/// → `{type:"rpcResult", id, result | error}`): file system, git, file index,
/// terminals, pickers. Heavy work runs off the main actor.
enum WebShellServices {
    struct RPCError: Error { let message: String }

    static let maxTextBytes: Int64 = TextFile.maxBytes
    static let maxImageBytes: Int64 = 12 * 1024 * 1024

    // MARK: Files

    nonisolated static func list(_ path: String, showHidden: Bool) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let rows = urls.compactMap { item -> (String, String, Bool)? in
            let name = item.lastPathComponent
            if name == ".DS_Store" { return nil }
            let values = try? item.resourceValues(forKeys: Set(keys))
            var isDir = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                var flag: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &flag) { isDir = flag.boolValue }
            }
            return (name, item.path, isDir)
        }
        .sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 }
            return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
        }
        return rows.map { ["name": $0.0, "path": $0.1, "dir": $0.2] }
    }

    nonisolated static func read(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            throw RPCError(message: "notFound")
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var result: [String: Any] = ["path": path, "size": size, "mtime": mtime]
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if let type, type.conforms(to: .image), type != .svg {
            guard size <= maxImageBytes, let data = try? Data(contentsOf: url) else {
                result["tooLarge"] = true
                return result
            }
            let mime = type.preferredMIMEType ?? "image/png"
            result["image"] = "data:\(mime);base64,\(data.base64EncodedString())"
            return result
        }
        guard size <= maxTextBytes else {
            result["tooLarge"] = true
            return result
        }
        guard let data = try? Data(contentsOf: url) else { throw RPCError(message: "unreadable") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            result["binary"] = true
            return result
        }
        result["text"] = text
        return result
    }

    nonisolated static func write(_ path: String, text: String, baseMtime: Double?, force: Bool) throws -> [String: Any] {
        let fm = FileManager.default
        if !force, let baseMtime, let attrs = try? fm.attributesOfItem(atPath: path),
           let current = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
           abs(current - baseMtime) > 0.001 {
            throw RPCError(message: "conflict")
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        let mtime = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ["mtime": mtime]
    }

    // MARK: Git

    nonisolated static func git(_ args: [String], cwd: String, limit: Int = 4_000_000) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + args
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (-1, "") }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count < limit { data.append(chunk) }
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data.prefix(limit), as: UTF8.self))
    }

    /// Working-tree changes vs HEAD (tracked) plus untracked files listed by name.
    nonisolated static func gitDiff(cwd: String) -> [String: Any] {
        let top = git(["rev-parse", "--show-toplevel"], cwd: cwd)
        guard top.status == 0 else { return ["repo": false] }
        let root = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
        var diff = git(["diff", "HEAD", "--no-color", "--no-ext-diff", "-M", "--relative"], cwd: cwd)
        if diff.status != 0 {
            // Repos without commits yet.
            diff = git(["diff", "--no-color", "--no-ext-diff", "--relative"], cwd: cwd)
        }
        let untracked = git(["ls-files", "--others", "--exclude-standard"], cwd: cwd).out
            .split(separator: "\n").prefix(200).map(String.init)
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["repo": true, "root": root, "branch": branch, "diff": diff.out, "untracked": untracked]
    }
}

// MARK: - Bridge integration

extension WebShellBridge {
    func handleRPC(_ body: [String: Any]) {
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        let method = body["method"] as? String ?? ""
        let params = body["params"] as? [String: Any] ?? [:]
        let reply: @MainActor (Result<Any, Error>) -> Void = { [weak self] result in
            switch result {
            case .success(let value):
                self?.post(["type": "rpcResult", "id": id, "result": value])
            case .failure(let error):
                let message = (error as? WebShellServices.RPCError)?.message ?? error.localizedDescription
                self?.post(["type": "rpcResult", "id": id, "error": message])
            }
        }
        func background(_ work: @escaping @Sendable () throws -> Any) {
            Task.detached(priority: .userInitiated) {
                let result: Result<Any, Error>
                do { result = .success(try work()) } catch { result = .failure(error) }
                let boxed = UncheckedBox(result)
                await MainActor.run { reply(boxed.value) }
            }
        }
        let path = (params["path"] as? String).map { model.normalizeWorkspacePath($0) } ?? ""
        switch method {
        case "fs.list":
            let hidden = params["hidden"] as? Bool ?? false
            background { try WebShellServices.list(path, showHidden: hidden) }
        case "fs.read":
            background { try WebShellServices.read(path) }
        case "fs.write":
            let text = params["text"] as? String ?? ""
            let base = (params["mtime"] as? NSNumber)?.doubleValue
            let force = params["force"] as? Bool ?? false
            background { try WebShellServices.write(path, text: text, baseMtime: base, force: force) }
        case "fs.search":
            let root = (params["root"] as? String) ?? model.inspectorRoot
            let query = params["query"] as? String ?? ""
            let limit = (params["limit"] as? NSNumber)?.intValue ?? 30
            model.fileIndex.ensureScanned(root: root)
            searchIndex(root: root, query: query, limit: limit, attempts: 12, reply: reply)
        case "git.diff":
            let cwd = (params["cwd"] as? String) ?? model.inspectorRoot
            background { WebShellServices.gitDiff(cwd: cwd) }
        case "term.open":
            let cwd = (params["cwd"] as? String) ?? model.inspectorRoot
            let cols = (params["cols"] as? NSNumber)?.intValue ?? 80
            let rows = (params["rows"] as? NSNumber)?.intValue ?? 24
            reply(.success(terminals.open(cwd: cwd, cols: cols, rows: rows)))
        case "ui.confirm":
            let alert = NSAlert()
            alert.messageText = params["message"] as? String ?? ""
            if let info = params["info"] as? String { alert.informativeText = info }
            alert.addButton(withTitle: params["ok"] as? String ?? "OK")
            alert.addButton(withTitle: params["cancel"] as? String ?? "取消".localized)
            if params["destructive"] as? Bool == true { alert.buttons.first?.hasDestructiveAction = true }
            if let window = hostView?.window {
                alert.beginSheetModal(for: window) { response in
                    MainActor.assumeIsolated { reply(.success(response == .alertFirstButtonReturn)) }
                }
            } else {
                reply(.success(alert.runModal() == .alertFirstButtonReturn))
            }
        case "pick.markdown":
            pickMarkdown(reply: reply)
        case "pick.folder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: model.workspacePath)
            panel.prompt = "选择".localized
            runPanel(panel) { urls in reply(.success(urls.first?.path ?? NSNull())) }
        case "pick.executable":
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
            panel.prompt = "选择".localized
            runPanel(panel) { urls in reply(.success(urls.first?.path ?? NSNull())) }
        default:
            if let value = handleSettingsRPC(method, params) {
                reply(.success(value))
            } else {
                reply(.failure(WebShellServices.RPCError(message: "unknown method \(method)")))
            }
        }
    }

    private func searchIndex(root: String, query: String, limit: Int, attempts: Int,
                             reply: @escaping @MainActor (Result<Any, Error>) -> Void) {
        let index = model.fileIndex
        if index.files.isEmpty, attempts > 0 {
            // The first scan is async; give it a moment before answering empty.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated {
                    self?.searchIndex(root: root, query: query, limit: limit, attempts: attempts - 1, reply: reply)
                }
            }
            return
        }
        let base = URL(fileURLWithPath: root)
        let rows = index.search(query, limit: limit).map { file -> [String: Any] in
            ["rel": file.relativePath, "path": base.appendingPathComponent(file.relativePath).path]
        }
        reply(.success(rows))
    }

    func runPanel(_ panel: NSOpenPanel, completion: @escaping @MainActor ([URL]) -> Void) {
        let done: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.urls : []) }
        }
        if let window = hostView?.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }

    private func pickMarkdown(reply: @escaping @MainActor (Result<Any, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MarkdownFile.contentTypes
        panel.message = "选择 Markdown 文件".localized
        panel.prompt = "打开".localized
        runPanel(panel) { urls in reply(.success(urls.map(\.path))) }
    }

    /// Native entry points (⌘O, Finder "Open With", Dock drop) land here.
    func openFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        if role != .main, let main = WebShellBridge.current, main !== self {
            main.openFiles(paths)
            return
        }
        sendCommand("openFiles", ["paths": paths])
    }

    func notifyFileChanged(_ path: String) {
        post(["type": "fileChanged", "path": path])
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
