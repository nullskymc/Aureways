import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 应用退出时显式终止交互终端；不依赖 PTY master 关闭带来的 SIGHUP，有竞态。
    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            WebShellBridge.current?.terminals.closeAll()
        }
    }

    // 关主窗口或 ⌘Q / Dock 退出：不杀进程，只收到菜单栏。真正退出走菜单栏「退出」。
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async {
            AppActivation.hideDockIfNoMainWindow()
        }
        return false
    }

    // ⌘Q is remapped to 关闭窗口, and Dock 退出 only hides to the menu bar. A quit
    // Apple Event from anything else (osascript / an installer, or logout and
    // shutdown) really quits: cancelling it is what made `tell application … to
    // quit` fail with -128 and what made the app interrupt logout.
    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if AppActivation.allowsTermination
                || AppActivation.isExternalQuitRequest(NSAppleEventManager.shared().currentAppleEvent) {
                AppActivation.allowsTermination = true
                return .terminateNow
            }
            AppActivation.resignToMenuBar()
            return .terminateCancel
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Return false so AppKit does not also order the window front.
        // A document open delivers reopen in the same turn; raising the window
        // then flashes it and drags it onto the file's screen.
        if MainActor.assumeIsolated({ AppActivation.isOpeningDocument }) { return false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !AppActivation.shouldSuppressReveal else { return }
                AppActivation.revealMainWindow()
            }
        }
        return false
    }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppActivation.receiveOpenedURLs(urls)
        }
    }
}

@main
struct AurewaysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        // Agent 进程退出后向其 stdin 写请求会触发 SIGPIPE，默认行为是杀掉整个 app。
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("Aureways", id: AppActivation.mainWindowID) {
            // One WKWebView fills the window (docs/web-shell.md).
            WebShellRoot(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        // Finder open must not retarget this scene. A retarget recreates the
        // web view (blank flash) and moves the window onto the file's screen.
        // AppDelegate.application(_:open:) switches the file tab instead.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话".localized) {
                    model.startNewSession()
                    WebShellBridge.current?.sendCommand("focusComposer")
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("打开 Markdown…".localized) {
                    WebShellBridge.current?.sendCommand("openMarkdown")
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…".localized) {
                    AppActivation.revealMainWindow()
                    WebShellBridge.current?.sendCommand("openSettings")
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("查找…".localized) {
                    WebShellBridge.current?.sendCommand("find")
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            CommandGroup(before: .sidebar) {
                Button("切换侧边栏".localized) {
                    WebShellBridge.current?.sendCommand("toggleSidebar")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("切换右侧标签区".localized) {
                    WebShellBridge.current?.sendCommand("toggleInspector")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Button("文件".localized) {
                    WebShellBridge.current?.sendCommand("showFiles")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("变更".localized) {
                    WebShellBridge.current?.sendCommand("showChanges")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("新建终端".localized) {
                    WebShellBridge.current?.sendCommand("newTerminal")
                }
                .keyboardShortcut("`", modifiers: [.control])
                Button("向右分栏".localized) {
                    WebShellBridge.current?.sendCommand("splitRight")
                }
                .keyboardShortcut("\\", modifiers: [.command])
                Divider()
            }
            CommandMenu("会话".localized) {
                Button("停止".localized) {
                    model.cancel()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(model.selectedSession?.isStreaming != true)
                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button("会话 %d".localized(index + 1)) {
                        model.selectSessionByIndex(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                    }
            }
            CommandGroup(replacing: .appTermination) {
                Button("关闭窗口".localized) {
                    AppActivation.resignToMenuBar()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent(model: model)
        } label: {
            MenuBarExtraLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
