import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 应用退出时显式终止交互终端；不依赖 PTY master 关闭带来的 SIGHUP，有竞态。
    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared?.terminateAllTerminals()
        }
    }

    // 关主窗口或 ⌘Q / Dock 退出：不杀进程，只收到菜单栏。真正退出走菜单栏「退出」。
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async {
            AppActivation.hideDockIfNoMainWindow()
        }
        return false
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if AppActivation.allowsTermination {
                return .terminateNow
            }
            AppActivation.resignToMenuBar()
            return .terminateCancel
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aurewaysRevealMainWindow, object: nil)
        }
        return true
    }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppActivation.receiveOpenedURLs(urls)
        }
    }

    #if DEBUG
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ScrollProbe.shared.start()
        }
    }
    #endif
}

@main
struct AurewaysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    /// Read once: switching the window root at runtime is not supported.
    private let legacyUI = WebShellFlag.useLegacy

    init() {
        // Agent 进程退出后向其 stdin 写请求会触发 SIGPIPE，默认行为是杀掉整个 app。
        signal(SIGPIPE, SIG_IGN)
    }

    /// Default: one WKWebView fills the window (docs/web-shell.md). The legacy
    /// SwiftUI split view is kept only behind `useLegacyNativeUI`.
    @ViewBuilder
    private var mainWindowContent: some View {
        if legacyUI {
            RootView()
                .environment(model)
                .environment(\.locale, model.displayLocale)
                .preferredColorScheme(model.colorScheme)
                .id(model.appLanguage)
                .frame(minWidth: 980, minHeight: 640)
        } else {
            WebShellRoot(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
    }

    var body: some Scene {
        Window("Aureways", id: AppActivation.mainWindowID) {
            mainWindowContent
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话".localized) {
                    model.startNewSession()
                    WebShellBridge.current?.sendCommand("focusComposer")
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("打开 Markdown…".localized) {
                    model.pickAndOpenMarkdownDocuments()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!legacyUI)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("查找…".localized) {
                    WebShellBridge.current?.sendCommand("find")
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(legacyUI)
            }
            CommandGroup(before: .sidebar) {
                Button("切换侧边栏".localized) {
                    WebShellBridge.current?.sendCommand("toggleSidebar")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(legacyUI)
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
                    .disabled(legacyUI)
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("关闭窗口".localized) {
                    AppActivation.resignToMenuBar()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, model.displayLocale)
                .preferredColorScheme(model.colorScheme)
                .id(model.appLanguage)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            StatusMenuView()
                .environment(model)
                .environment(\.locale, model.displayLocale)
                .id(model.appLanguage)
        } label: {
            MenuBarExtraLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
