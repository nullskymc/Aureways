import AppKit
import SwiftUI

// MARK: - Workspace + Sessions

struct WorkspaceSessionTree: View {
    @Environment(AppModel.self) private var model

    var visibleWorkspaces: [WorkspaceRecord] {
        model.visibleWorkspaces
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("工作区")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.addWorkspace()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("添加工作区")
            }
            .padding(.horizontal, 10)

            ForEach(visibleWorkspaces) { workspace in
                WorkspaceGroupView(
                    workspace: workspace,
                    sessions: model.sessions(inWorkspace: workspace.path)
                )
            }
        }
    }
}

struct WorkspaceGroupView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let sessions: [ChatSession]
    @State private var isExpanded = true
    @State private var showAll = false
    @State private var isHovered = false

    var isCurrent: Bool {
        model.workspacePath == workspace.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Button {
                    model.selectWorkspace(workspace.path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCurrent ? "folder.fill" : "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workspace.name)
                                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent || isHovered ? .primary : .secondary)
                                .lineLimit(1)
                            if isCurrent, let branch = model.workspaceBranch {
                                Text(branch)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassRowHighlight(isSelected: false, isHovered: isHovered, cornerRadius: 6)
            .onHover { isHovered = $0 }
            .help(workspace.path)
            .contextMenu {
                Button("设为当前工作区") {
                    model.selectWorkspace(workspace.path)
                }
                Button("在 Finder 中打开") {
                    model.openWorkspaceInFinder(workspace.path)
                }
                Divider()
                Button("从列表移除", role: .destructive) {
                    model.removeWorkspace(workspace.path)
                }
            }

            if isExpanded {
                let displayCount = showAll ? sessions.count : min(sessions.count, 5)
                ForEach(Array(sessions.prefix(displayCount))) { session in
                    SessionNavItem(session: session)
                        .padding(.leading, 10)
                }
                if sessions.count > 5 {
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Text(showAll ? "收起" : "展开显示 (\(sessions.count - 5) 条更多)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}


// MARK: - Session Nav Item

struct SessionNavItem: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    @State private var isHovered = false

    var isSelected: Bool {
        model.selectedSessionID == session.id
    }

    var shortcutBadge: String? {
        model.sessionShortcut(for: session)
    }

    var body: some View {
        Button {
            model.select(session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if session.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(sessionDot(session.phase))
                        .frame(width: 6, height: 6)
                }

                Text(session.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHovered, let shortcut = shortcutBadge {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassRowHighlight(isSelected: isSelected, isHovered: isHovered, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("关闭会话") {
                model.close(session)
            }
            Button("从列表移除") {
                model.forget(session)
            }
            if model.canDelete(session) {
                Button("从 Agent 删除", role: .destructive) {
                    model.delete(session)
                }
            }
            Button("复制标题") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.title, forType: .string)
            }
            Divider()
            Button("在 Finder 中查看工作区") {
                model.openWorkspaceInFinder(session.cwd)
            }
        }
    }

    private func sessionDot(_ phase: SessionPhase) -> Color {
        switch phase {
        case .ready: return Palette.moss
        case .failed: return Color.red
        case .connecting: return Palette.gold
        case .idle: return Color.secondary.opacity(0.45)
        }
    }
}

