import SwiftUI

// MARK: - File Browser Tab

private struct FileNode: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
}

private struct VisibleNode: Identifiable {
    let node: FileNode
    let depth: Int
    /// 过滤模式下命中文件所在的相对目录；树模式为 nil。
    var parentHint: String?

    var id: String { node.path }
}

private struct FileTreeState {
    private var childrenCache: [String: [FileNode]] = [:]
    private var expanded: Set<String> = []

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

// MARK: - File Filter Scan

/// nonisolated：递归枚举不能放进 View.body，也不能绑在主线程按键路径上。
private enum FileFilterScan {
    static let maxResults = 80

    private static let excludedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "dist", "target", ".next", "Pods",
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

// MARK: - File Visual Cues

struct FileVisual {
    let icon: String
    let color: Color
    let language: String

    static func `for`(path: String, isDirectory: Bool = false, isExpanded: Bool = false) -> FileVisual {
        if isDirectory {
            return FileVisual(
                icon: isExpanded ? "folder.fill" : "folder",
                color: Palette.accent,
                language: "目录"
            )
        }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        if name == "package.swift" || ext == "swift" {
            return FileVisual(icon: "swift", color: .orange, language: "Swift")
        } else if ext == "xcodeproj" || ext == "xcworkspace" {
            return FileVisual(icon: "hammer.fill", color: Palette.sky, language: "Xcode")
        } else if ["md", "markdown"].contains(ext) {
            return FileVisual(icon: "text.book.closed.fill", color: Palette.sky, language: "Markdown")
        } else if ["txt", "rtf"].contains(ext) {
            return FileVisual(icon: "doc.text.fill", color: Palette.sky, language: "文本")
        } else if ["json"].contains(ext) {
            return FileVisual(icon: "curlybraces", color: Palette.gold, language: "JSON")
        } else if ["yaml", "yml"].contains(ext) {
            return FileVisual(icon: "curlybraces", color: Palette.gold, language: "YAML")
        } else if ["plist", "toml", "xml"].contains(ext) {
            return FileVisual(icon: "curlybraces", color: Palette.gold, language: "配置")
        } else if ["sh", "zsh", "bash", "command"].contains(ext) {
            return FileVisual(icon: "terminal.fill", color: Palette.moss, language: "Shell")
        } else if name == "makefile" {
            return FileVisual(icon: "terminal.fill", color: Palette.moss, language: "Makefile")
        } else if ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "icns", "heic"].contains(ext) {
            return FileVisual(icon: "photo.fill", color: .purple, language: "图片")
        } else if ["html", "htm"].contains(ext) {
            return FileVisual(icon: "globe", color: .cyan, language: "HTML")
        } else if ["css", "scss", "less"].contains(ext) {
            return FileVisual(icon: "paintbrush.fill", color: .cyan, language: "CSS")
        } else if ["js", "jsx"].contains(ext) {
            return FileVisual(icon: "globe", color: .yellow, language: "JavaScript")
        } else if ["ts", "tsx"].contains(ext) {
            return FileVisual(icon: "globe", color: .blue, language: "TypeScript")
        } else if name.hasPrefix(".git") || ext == "diff" || ext == "patch" {
            return FileVisual(icon: "arrow.triangle.branch", color: Color.secondary, language: "Git")
        } else if ["py"].contains(ext) {
            return FileVisual(icon: "chevron.left.forwardslash.chevron.right", color: .indigo, language: "Python")
        } else if ["rs"].contains(ext) {
            return FileVisual(icon: "chevron.left.forwardslash.chevron.right", color: .red, language: "Rust")
        } else if ["go"].contains(ext) {
            return FileVisual(icon: "chevron.left.forwardslash.chevron.right", color: .cyan, language: "Go")
        } else if ["c", "cpp", "h", "hpp", "m", "mm"].contains(ext) {
            return FileVisual(icon: "chevron.left.forwardslash.chevron.right", color: .indigo, language: "C/C++")
        } else {
            return FileVisual(icon: "doc.text.fill", color: Color.secondary.opacity(0.8), language: "文本")
        }
    }
}

// MARK: - FileBrowserTabView

struct FileBrowserTabView: View {
    @Environment(AppModel.self) private var model
    var isActive: Bool = true
    @State private var tree = FileTreeState()
    @State private var filterQuery = ""
    @State private var filterResults: [VisibleNode] = []
    @State private var isFilterPending = false
    @State private var filterTask: Task<Void, Never>?

    private var trimmedQuery: String {
        filterQuery.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        let isFiltering = !trimmedQuery.isEmpty
        let displayedNodes = isFiltering ? filterResults : tree.visibleNodes(root: model.workspacePath)

        VStack(alignment: .leading, spacing: 0) {
            WorkspaceControlBar(
                query: $filterQuery,
                isActive: isActive,
                onReload: {
                    tree.invalidateAll(root: model.workspacePath)
                    scheduleFilter(filterQuery)
                },
                onCollapseAll: {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        tree.collapseAll()
                    }
                }
            )

            ScrollView {
                if displayedNodes.isEmpty {
                    emptyState(isFiltering: isFiltering)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayedNodes) { item in
                            FileNodeRow(
                                node: item.node,
                                depth: isFiltering ? 0 : item.depth,
                                isExpanded: isFiltering ? false : tree.isExpanded(item.node.path),
                                isSelected: model.activePaneTabId == PaneTab.file(path: item.node.path).id,
                                parentHint: item.parentHint,
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        if isFiltering {
                                            filterQuery = ""
                                            tree.expandTo(item.node.path, root: model.workspacePath)
                                        } else {
                                            tree.toggle(item.node)
                                        }
                                    }
                                },
                                onOpen: { model.openFileTab(path: item.node.path) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)

            WorkspaceStatusBar(count: displayedNodes.count, isFiltering: isFiltering)
        }
        .onAppear { tree.reload(root: model.workspacePath) }
        .onChange(of: model.workspacePath) { _, newValue in
            tree.reload(root: newValue)
            filterResults = []
            scheduleFilter(filterQuery)
        }
        .onChange(of: model.browserInvalidationToken) {
            tree.invalidateAll(root: model.workspacePath)
            scheduleFilter(filterQuery)
        }
        .onChange(of: filterQuery) { _, newValue in
            scheduleFilter(newValue)
        }
        .onDisappear {
            filterTask?.cancel()
        }
    }

    @ViewBuilder
    private func emptyState(isFiltering: Bool) -> some View {
        VStack(spacing: 8) {
            if isFiltering, isFilterPending {
                ProgressView()
                    .controlSize(.small)
                Text("正在搜索…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: isFiltering ? "magnifyingglass" : "folder")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(isFiltering ? "未找到匹配文件" : "工作区暂无文件")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @MainActor
    private func scheduleFilter(_ query: String) {
        filterTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            filterResults = []
            isFilterPending = false
            return
        }
        isFilterPending = true
        let root = model.workspacePath
        filterTask = Task {
            // 连续输入时不扫盘，停 150ms 再跑一次。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await FileFilterScan.scan(root: root, query: trimmed)
            guard !Task.isCancelled else { return }
            filterResults = found
            isFilterPending = false
        }
    }
}

// MARK: - Workspace Control Bar

private struct WorkspaceControlBar: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    var isActive: Bool = true
    let onReload: () -> Void
    let onCollapseAll: () -> Void

    @FocusState private var filterFocused: Bool
    @State private var isReloadHovered = false
    @State private var isFinderHovered = false
    @State private var isCollapseHovered = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)

                TextField("快速过滤文件...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($filterFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, query.isEmpty ? 8 : 2)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.badgeBg.opacity(0.50))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 0.5)
            )
            .frame(minWidth: 60, maxWidth: .infinity)

            HStack(spacing: 2) {
                Button(action: onCollapseAll) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isCollapseHovered ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isCollapseHovered ? Palette.cardHover.opacity(0.55) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isCollapseHovered = $0 }
                .help("全部折叠")

                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isReloadHovered ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isReloadHovered ? Palette.cardHover.opacity(0.55) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isReloadHovered = $0 }
                .help("刷新文件列表")

                Button {
                    model.openWorkspaceInFinder()
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isFinderHovered ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isFinderHovered ? Palette.cardHover.opacity(0.55) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isFinderHovered = $0 }
                .help("在 Finder 中显示工作区")
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .onChange(of: isActive) { _, active in
            if !active { filterFocused = false }
        }
    }
}

// MARK: - File Node Row

private struct FileNodeRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    var isSelected: Bool = false
    /// 过滤模式下的相对目录；nil 表示树模式。
    var parentHint: String?
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var isHovered = false

    private var relativePath: String {
        let prefix = model.workspacePath + "/"
        return node.path.hasPrefix(prefix) ? String(node.path.dropFirst(prefix.count)) : node.path
    }

    var body: some View {
        Button(action: node.isDirectory ? onToggle : onOpen) {
            HStack(spacing: 6) {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }

                let visual = FileVisual.for(path: node.path, isDirectory: node.isDirectory, isExpanded: isExpanded)
                Image(systemName: visual.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(visual.color)
                    .frame(width: 16)

                Text(node.name)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isHovered || isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)
                    .layoutPriority(1)

                if let parentHint {
                    Text(parentHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0)
                }

                Spacer()
            }
            .padding(.leading, 10 + CGFloat(depth) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 4.5)
            .contentShape(Rectangle())
            .glassRowHighlight(isSelected: isSelected, isHovered: isHovered, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if node.isDirectory {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                }
            } else {
                Button("打开") {
                    onOpen()
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                }
                Divider()
                Button("复制相对路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(relativePath, forType: .string)
                }
                Button("复制绝对路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                }
            }
        }
        .help(node.path)
    }
}

// MARK: - Workspace Status Bar

private struct WorkspaceStatusBar: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let isFiltering: Bool
    @State private var isTerminalHovered = false

    private var countLabel: String {
        guard isFiltering else { return "\(count) 个项目" }
        return count >= FileFilterScan.maxResults
            ? "匹配 \(count)+ 个文件"
            : "匹配 \(count) 个文件"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Text(countLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.openTerminalTab()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9.5))
                    Text("终端")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .foregroundStyle(isTerminalHovered ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isTerminalHovered ? Palette.cardHover.opacity(0.5) : Palette.badgeBg.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
            .onHover { isTerminalHovered = $0 }
            .help("打开集成终端")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Palette.badgeBg.opacity(0.45))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.splitDivider)
                .frame(height: 1)
        }
    }
}
