import AppKit
import SwiftUI

struct PaneTabBar: View {
    @Environment(AppModel.self) private var model
    @State private var hoveredTabId: String?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.paneTabs) { tab in
                        PaneTabChip(
                            tab: tab,
                            isActive: model.activePaneTabId == tab.id,
                            isHovered: hoveredTabId == tab.id,
                            isDirty: isDirty(tab)
                        )
                        .onHover { hovering in
                            hoveredTabId = hovering ? tab.id : (hoveredTabId == tab.id ? nil : hoveredTabId)
                        }
                    }
                }
            }

            Menu {
                Button {
                    model.openTerminalTab()
                } label: {
                    Label("新建终端", systemImage: "terminal")
                }
                Button {
                    model.selectPaneTab(PaneTab.browser.id)
                } label: {
                    Label("文件浏览器", systemImage: "folder")
                }
                Button {
                    model.openInfoTab()
                } label: {
                    Label("会话信息", systemImage: "info.circle")
                }
                Divider()
                Button {
                    model.openWorkspaceInFinder()
                } label: {
                    Label("在 Finder 中显示工作区", systemImage: "macwindow")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("新建标签")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func isDirty(_ tab: PaneTab) -> Bool {
        if case .file(let path) = tab {
            return model.fileTabStates[path]?.isDirty == true
        }
        return false
    }
}

private struct PaneTabChip: View {
    @Environment(AppModel.self) private var model
    let tab: PaneTab
    let isActive: Bool
    let isHovered: Bool
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tab.icon)
                .font(.system(size: 10))
            Text(model.paneTabTitle(tab))
                .font(.system(size: 11))
                .lineLimit(1)
            if isDirty {
                Circle()
                    .fill(Palette.gold)
                    .frame(width: 5, height: 5)
            }
            if tab.isClosable, isHovered || isActive {
                Button {
                    model.closePaneTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(isActive ? .primary : .secondary)
        .background {
            Capsule()
                .fill(isActive ? Palette.selection : (isHovered ? Palette.badgeBg : .clear))
        }
        .contentShape(Capsule())
        .onTapGesture {
            model.selectPaneTab(tab.id)
        }
        .contextMenu {
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
            }
        }
        .help(model.paneTabTitle(tab))
    }
}
