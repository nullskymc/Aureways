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
            if AppActivation.consumeIgnoreNextReopen() { return }
            NotificationCenter.default.post(name: .aurewaysRevealMainWindow, object: nil)
        }
        return true
    }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppActivation.receiveOpenedURLs(urls)
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            #if DEBUG
            ScrollProbe.shared.start()
            #endif
            AppActivation.flushPendingOpens()
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
            RootView()
                .environment(model)
                .environment(\.locale, model.displayLocale)
                .preferredColorScheme(model.colorScheme)
                .id(model.appLanguage)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话".localized) {
                    model.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("打开 Markdown…".localized) {
                    model.pickAndOpenMarkdownDocuments()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .appTermination) {
                Button("关闭窗口".localized) {
                    AppActivation.resignToMenuBar()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }

        WindowGroup(id: AppActivation.markdownWindowID, for: String.self) { $path in
            if let path, !path.isEmpty {
                MarkdownDocumentView(path: path)
                    .environment(\.locale, model.displayLocale)
                    .preferredColorScheme(model.colorScheme)
                    .id(model.appLanguage)
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 920)
        .defaultLaunchBehavior(.suppressed)

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
