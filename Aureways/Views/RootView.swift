import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            MainWorkspaceView()
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(model.selectedSession?.title ?? "新对话")
        .navigationSubtitle(workspaceSubtitle)
        .toolbarTitleMenu {
            workspaceMenu
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "搜索会话")
        .toolbar {
            if let session = model.selectedSession {
                if session.phase == .connecting {
                    ToolbarItem(placement: .automatic) {
                        ProgressView()
                            .controlSize(.small)
                            .help("正在连接 \(session.agent.title)")
                    }
                } else if case .failed = session.phase {
                    ToolbarItem(placement: .automatic) {
                        Button("重试", systemImage: "arrow.clockwise") {
                            model.retry(session)
                        }
                    }
                } else if session.phase == .idle {
                    ToolbarItem(placement: .automatic) {
                        Button("打开", systemImage: "arrow.clockwise") {
                            model.select(session)
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.inspectorOpen.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(model.inspectorOpen ? .primary : .secondary)
                }
                .help("检查器 (⌘B / ⌥⌘I)")
                .keyboardShortcut("b", modifiers: [.command])
            }
        }
        .liquidGlassWindow(appearance: model.colorScheme)
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background {
            // Hidden keyboard shortcut buttons for ⌘1 ~ ⌘9
            ForEach(0..<9, id: \.self) { idx in
                Button("") {
                    model.selectSessionByIndex(idx)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command])
                .opacity(0)
                .allowsHitTesting(false)
            }
            Button("") {
                model.inspectorOpen.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private var workspaceSubtitle: String {
        if let branch = model.workspaceBranch, !branch.isEmpty {
            return "\(model.currentWorkspaceName) · \(branch)"
        }
        return model.currentWorkspaceName
    }

    @ViewBuilder
    private var workspaceMenu: some View {
        Section("工作区") {
            ForEach(model.workspaces) { workspace in
                Button {
                    model.selectWorkspace(workspace.path)
                } label: {
                    if workspace.path == model.workspacePath {
                        Label(workspace.name, systemImage: "checkmark")
                    } else {
                        Text(workspace.name)
                    }
                }
            }
        }
        Button("添加工作区...") { model.addWorkspace() }
        Button("在 Finder 中打开当前工作区") { model.openWorkspaceInFinder() }
    }
}

struct MainWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        workspaceColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: Binding(
                get: { model.inspectorOpen },
                set: { model.inspectorOpen = $0 }
            )) {
                InspectorPaneView()
                    .inspectorColumnWidth(min: 320, ideal: 440, max: 600)
            }
    }

    @ViewBuilder
    private var workspaceColumn: some View {
        if let session = model.selectedSession {
            TranscriptView(session: session)
        } else {
            EmptyWorkspaceLanding()
        }
    }
}

