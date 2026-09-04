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
        // 系统分段控件自己吃掉右键，SwiftUI `.contextMenu` 出不来。
        .overlay {
            TabPickerRightClickCatcher(
                tabs: model.paneTabs,
                onClose: { model.closePaneTab($0) },
                onCloseOthers: { model.closeOtherPaneTabs(keeping: $0) },
                onReveal: { path in
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                },
                onCopyPath: { path in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            )
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

}

/// 只拦截右键 / Control-点击，左键仍落到底下的分段选择器。
private struct TabPickerRightClickCatcher: NSViewRepresentable {
    var tabs: [PaneTab]
    var onClose: (PaneTab) -> Void
    var onCloseOthers: (PaneTab) -> Void
    var onReveal: (String) -> Void
    var onCopyPath: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        let coordinator = context.coordinator
        coordinator.tabs = tabs
        coordinator.onClose = onClose
        coordinator.onCloseOthers = onCloseOthers
        coordinator.onReveal = onReveal
        coordinator.onCopyPath = onCopyPath
        nsView.coordinator = coordinator
        nsView.tabCount = tabs.count
    }

    @MainActor
    final class Coordinator: NSObject {
        var tabs: [PaneTab] = []
        var onClose: ((PaneTab) -> Void)?
        var onCloseOthers: ((PaneTab) -> Void)?
        var onReveal: ((String) -> Void)?
        var onCopyPath: ((String) -> Void)?

        func tab(for id: String) -> PaneTab? {
            tabs.first(where: { $0.id == id })
        }

        @objc func close(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let tab = tab(for: id) else { return }
            onClose?(tab)
        }

        @objc func closeOthers(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let tab = tab(for: id) else { return }
            onCloseOthers?(tab)
        }

        @objc func reveal(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            onReveal?(path)
        }

        @objc func copyPath(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            onCopyPath?(path)
        }
    }

    @MainActor
    final class CatcherView: NSView {
        weak var coordinator: Coordinator?
        var tabCount = 1

        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return self
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return event.modifierFlags.contains(.control) ? self : nil
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                showMenu(for: event)
            }
        }

        private func showMenu(for event: NSEvent) {
            guard let coordinator, tabCount > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let index = segmentIndex(at: point)
            guard coordinator.tabs.indices.contains(index) else { return }
            let tab = coordinator.tabs[index]
            guard let menu = makeMenu(for: tab, coordinator: coordinator), !menu.items.isEmpty else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        private func segmentIndex(at point: NSPoint) -> Int {
            let count = max(tabCount, 1)
            let inset: CGFloat = 2
            let usable = max(bounds.width - inset * 2, 1)
            let x = min(max(point.x - inset, 0), usable - 0.001)
            return min(count - 1, Int(x / (usable / CGFloat(count))))
        }

        private func makeMenu(for tab: PaneTab, coordinator: Coordinator) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if tab.isClosable {
                let close = NSMenuItem(title: "关闭", action: #selector(Coordinator.close(_:)), keyEquivalent: "")
                close.target = coordinator
                close.representedObject = tab.id
                menu.addItem(close)

                let others = NSMenuItem(title: "关闭其它", action: #selector(Coordinator.closeOthers(_:)), keyEquivalent: "")
                others.target = coordinator
                others.representedObject = tab.id
                menu.addItem(others)
            }
            if case .file(let path) = tab {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(Coordinator.reveal(_:)), keyEquivalent: "")
                reveal.target = coordinator
                reveal.representedObject = path
                menu.addItem(reveal)

                let copy = NSMenuItem(title: "复制路径", action: #selector(Coordinator.copyPath(_:)), keyEquivalent: "")
                copy.target = coordinator
                copy.representedObject = path
                menu.addItem(copy)
            }
            return menu.items.isEmpty ? nil : menu
        }
    }
}
