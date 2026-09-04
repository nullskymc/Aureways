import AppKit
import SwiftUI

/// 检查器相关工具栏项：分段开关用系统 `Picker`，加号和侧栏按钮各占一格，
/// 让窗口工具栏自己做 Liquid Glass，而不是塞进一颗自制胶囊。
struct InspectorToolbarContent: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if model.inspectorOpen {
            ToolbarItem(placement: .primaryAction) {
                panePicker
            }
            ToolbarItem(placement: .primaryAction) {
                newTabMenu
            }
        }
        ToolbarItem(placement: .primaryAction) {
            inspectorToggle
        }
    }

    private var panePicker: some View {
        Picker("检查器", selection: Binding(
            get: { model.activePaneTabId },
            set: { model.selectPaneTab($0) }
        )) {
            ForEach(model.paneTabs) { tab in
                Label(title(for: tab), systemImage: symbol(for: tab))
                    .tag(tab.id)
                    .help(model.paneTabTitle(tab))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .contextMenu {
            if let tab = currentTab {
                tabContextMenu(tab)
            }
        }
    }

    private var newTabMenu: some View {
        Menu {
            Button("新建终端", systemImage: "terminal") {
                model.openTerminalTab()
            }
            Button("文件浏览器", systemImage: "folder") {
                model.selectPaneTab(PaneTab.browser.id)
            }
            Button("会话信息", systemImage: "info.circle") {
                model.openInfoTab()
            }
            if let tab = currentTab, tab.isClosable {
                Divider()
                Button("关闭当前标签", systemImage: "xmark") {
                    model.closePaneTab(tab)
                }
                Button("关闭其它标签") {
                    model.closeOtherPaneTabs(keeping: tab)
                }
            }
            Divider()
            Button("在 Finder 中显示工作区", systemImage: "macwindow") {
                model.openWorkspaceInFinder()
            }
        } label: {
            Label("新建标签", systemImage: "plus")
        }
        .help("新建标签")
    }

    private var inspectorToggle: some View {
        Button {
            model.inspectorOpen.toggle()
        } label: {
            Label(
                model.inspectorOpen ? "收起检查器" : "展开检查器",
                systemImage: "sidebar.right"
            )
        }
        .help(model.inspectorOpen ? "收起检查器 (⌘B / ⌥⌘I)" : "展开检查器 (⌘B / ⌥⌘I)")
    }

    private var currentTab: PaneTab? {
        model.paneTabs.first(where: { $0.id == model.activePaneTabId })
    }

    private func title(for tab: PaneTab) -> String {
        let name = model.paneTabTitle(tab)
        if isDirty(tab) { return name + " ●" }
        return name
    }

    private func symbol(for tab: PaneTab) -> String {
        switch tab {
        case .browser: return "folder"
        case .info: return "info.circle"
        case .terminal: return "terminal"
        case .file(let path): return FileVisual.for(path: path).icon
        }
    }

    private func isDirty(_ tab: PaneTab) -> Bool {
        if case .file(let path) = tab {
            return model.fileTabStates[path]?.isDirty == true
        }
        return false
    }

    @ViewBuilder
    private func tabContextMenu(_ tab: PaneTab) -> some View {
        if tab.isClosable {
            Button("关闭") {
                model.closePaneTab(tab)
            }
            Button("关闭其它") {
                model.closeOtherPaneTabs(keeping: tab)
            }
        }
        if case .file(let path) = tab {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}
