import Foundation

// MARK: - File Node

struct FileNode: Identifiable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }

    init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }
}

// MARK: - Visible Node in Tree

struct VisibleNode: Identifiable, Sendable {
    let node: FileNode
    let depth: Int
    /// 过滤模式下命中文件所在相对目录；树模式为 nil。
    var parentHint: String?

    var id: String { node.path }

    init(node: FileNode, depth: Int, parentHint: String? = nil) {
        self.node = node
        self.depth = depth
        self.parentHint = parentHint
    }
}

// MARK: - File Tree State Management

struct FileTreeState: Sendable {
    private var childrenCache: [String: [FileNode]] = [:]
    private var expanded: Set<String> = []

    init() {}

    func children(of path: String) -> [FileNode] {
        childrenCache[path] ?? []
    }

    func isExpanded(_ path: String) -> Bool {
        expanded.contains(path)
    }

    func visibleNodes(root: String) -> [VisibleNode] {
        var result: [VisibleNode] = []
        appendVisible(path: root, depth: 0, into: &result)
        return result
    }

    private func appendVisible(path: String, depth: Int, into result: inout [VisibleNode]) {
        for node in children(of: path) {
            result.append(VisibleNode(node: node, depth: depth))
            if node.isDirectory, isExpanded(node.path) {
                appendVisible(path: node.path, depth: depth + 1, into: &result)
            }
        }
    }

    mutating func reload(root: String) {
        expanded = []
        childrenCache = [:]
        loadChildren(root)
    }

    mutating func collapseAll() {
        expanded.removeAll()
    }

    mutating func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
            loadChildren(node.path)
        }
    }

    mutating func invalidateAll(root: String) {
        childrenCache = [:]
        loadChildren(root)
        for path in expanded {
            loadChildren(path)
        }
    }

    mutating func expandTo(_ directoryPath: String, root: String) {
        loadChildren(root)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard directoryPath.hasPrefix(prefix) else { return }
        var current = root
        let relative = String(directoryPath.dropFirst(prefix.count))
        for component in relative.split(separator: "/") {
            current = current + "/" + component
            expanded.insert(current)
            loadChildren(current)
        }
    }

    private mutating func loadChildren(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        childrenCache[path] = urls.compactMap { item -> FileNode? in
            let isDirectory = (try? item.resourceValues(forKeys: Set(keys)))?.isDirectory == true
            return FileNode(path: item.path, name: item.lastPathComponent, isDirectory: isDirectory)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - File Filter BFS Scan

/// nonisolated：递归枚举不能放进 View.body，也不能绑在主线程按键路径上。
enum FileFilterScan: Sendable {
    static let maxResults = 80

    private static let excludedDirectories: Set<String> = [
        ".git", ".aureways", "node_modules", ".build", "DerivedData", "dist", "target", ".next", "Pods",
    ]
    private static let maxVisited = 20_000
    private static let maxCollected = 400

    nonisolated static func scan(root: String, query: String) async -> [VisibleNode] {
        files(root: root, query: query)
    }

    nonisolated static func files(root: String, query: String) -> [VisibleNode] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let prefix = rootURL.path + "/"
        var queue: [URL] = [rootURL]
        var cursor = 0
        var visited = 0
        var collected: [VisibleNode] = []

        // BFS：浅层命中排在前面，符合过滤时的直觉。
        while cursor < queue.count, visited < maxVisited, collected.count < maxCollected {
            if Task.isCancelled { return [] }
            let directory = queue[cursor]
            cursor += 1
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in contents {
                if Task.isCancelled { return [] }
                visited += 1
                guard visited <= maxVisited else { break }
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let name = item.lastPathComponent
                let relative = item.path.hasPrefix(prefix)
                    ? String(item.path.dropFirst(prefix.count))
                    : name
                if isDirectory {
                    if !excludedDirectories.contains(name) {
                        queue.append(item)
                    }
                    if matches(query, name: name, relative: relative) {
                        let parent = (relative as NSString).deletingLastPathComponent
                        collected.append(VisibleNode(
                            node: FileNode(path: item.path, name: name, isDirectory: true),
                            depth: 0,
                            parentHint: parent.isEmpty ? nil : parent
                        ))
                    }
                    continue
                }
                guard matches(query, name: name, relative: relative) else { continue }
                let parent = (relative as NSString).deletingLastPathComponent
                collected.append(VisibleNode(
                    node: FileNode(path: item.path, name: name, isDirectory: false),
                    depth: 0,
                    parentHint: parent.isEmpty ? nil : parent
                ))
            }
        }

        collected.sort { lhs, rhs in
            if lhs.node.isDirectory != rhs.node.isDirectory { return lhs.node.isDirectory }
            let lhsDepth = lhs.parentHint?.split(separator: "/").count ?? 0
            let rhsDepth = rhs.parentHint?.split(separator: "/").count ?? 0
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
        }
        return Array(collected.prefix(maxResults))
    }

    nonisolated private static func matches(_ query: String, name: String, relative: String) -> Bool {
        name.localizedCaseInsensitiveContains(query) || relative.localizedCaseInsensitiveContains(query)
    }
}
