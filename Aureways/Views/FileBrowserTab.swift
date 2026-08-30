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

    mutating func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
            loadChildren(node.path)
        }
    }

    mutating func invalidateAll() {
        childrenCache = [:]
        for path in expanded {
            loadChildren(path)
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

struct FileBrowserTabView: View {
    @Environment(AppModel.self) private var model
    @State private var tree = FileTreeState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.visibleNodes(root: model.workspacePath)) { item in
                        FileNodeRow(
                            node: item.node,
                            depth: item.depth,
                            isExpanded: tree.isExpanded(item.node.path),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    tree.toggle(item.node)
                                }
                            },
                            onOpen: { model.openFileTab(path: item.node.path) }
                        )
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear { tree.reload(root: model.workspacePath) }
        .onChange(of: model.workspacePath) { _, newValue in
            tree.reload(root: newValue)
        }
        .onChange(of: model.browserInvalidationToken) {
            tree.invalidateAll()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("工作区文件")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(model.currentWorkspaceName)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button {
                tree.reload(root: model.workspacePath)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: node.isDirectory ? onToggle : onOpen) {
            HStack(spacing: 6) {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(node.isDirectory ? Palette.accent : .secondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 10 + CGFloat(depth) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .glassRowHighlight(isSelected: false, isHovered: isHovered, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(node.path)
    }
}
