import Foundation
import Observation

struct IndexedFile: Identifiable, Equatable {
    var id: String { relativePath }
    let path: String
    let relativePath: String
}

// 大仓库全量枚举无意义：目录深度与文件数封顶，重目录直接跳过。
private let excludedDirectoryNames: Set<String> = [
    ".git", "node_modules", ".build", "DerivedData", "dist", "target", ".next", "Pods",
]
private let scanMaxDepth = 6
private let scanMaxFiles = 4000

// @Observable：后台扫描完成写 files 时，正在读它的 ComposerCard 补全弹层自动刷新。
@Observable
@MainActor
final class WorkspaceFileIndex {
    private(set) var files: [IndexedFile] = []
    private var scannedRoot: String?
    private var scanTask: Task<Void, Never>?

    func ensureScanned(root: String) {
        guard root != scannedRoot else { return }
        scanTask?.cancel()
        scannedRoot = root
        files = []
        let rootURL = URL(fileURLWithPath: root)
        scanTask = Task.detached(priority: .utility) {
            let collected = Self.scan(rootURL: rootURL)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.scannedRoot == root else { return }
                self.files = collected
            }
        }
    }

    func search(_ query: String, limit: Int = 20) -> [IndexedFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(files.prefix(limit)) }
        let loweredQuery = trimmed.lowercased()

        var scored: [(file: IndexedFile, score: Int)] = []
        for file in files {
            let name = (file.relativePath as NSString).lastPathComponent.lowercased()
            let path = file.relativePath.lowercased()
            if let score = matchScore(query: loweredQuery, name: name, path: path) {
                scored.append((file, score))
            }
        }
        scored.sort {
            $0.score != $1.score ? $0.score < $1.score : $0.file.relativePath.count < $1.file.relativePath.count
        }
        return scored.prefix(limit).map(\.file)
    }

    /// 0 文件名前缀 < 1 文件名包含 < 2 文件名子序列 < 3 路径包含 < 4 路径子序列
    private func matchScore(query: String, name: String, path: String) -> Int? {
        if name.hasPrefix(query) { return 0 }
        if name.contains(query) { return 1 }
        if isSubsequence(query, of: name) { return 2 }
        if path.contains(query) { return 3 }
        if isSubsequence(query, of: path) { return 4 }
        return nil
    }

    private func isSubsequence(_ query: String, of target: String) -> Bool {
        var index = target.startIndex
        for character in query {
            guard let found = target[index...].firstIndex(of: character) else { return false }
            index = target.index(after: found)
        }
        return true
    }

    private nonisolated static func scan(rootURL: URL) -> [IndexedFile] {
        var result: [IndexedFile] = []
        var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
        while !queue.isEmpty, result.count < scanMaxFiles {
            let current = queue.removeFirst()
            guard current.depth < scanMaxDepth else { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let sorted = contents.sorted { lhs, rhs in
                let lhsIsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let rhsIsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if lhsIsDir != rhsIsDir { return lhsIsDir }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            for item in sorted {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if excludedDirectoryNames.contains(item.lastPathComponent) { continue }
                    if current.depth + 1 < scanMaxDepth { queue.append((item, current.depth + 1)) }
                    continue
                }
                if result.count >= scanMaxFiles { break }
                let prefix = rootURL.path + "/"
                let relativePath = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.lastPathComponent
                result.append(IndexedFile(path: item.path, relativePath: relativePath))
            }
        }
        return result
    }
}
