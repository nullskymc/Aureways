import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 应用退出时显式终止交互终端；不依赖 PTY master 关闭带来的 SIGHUP，有竞态。
    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared?.terminateAllTerminals()
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

    init() {
        // Agent 进程退出后向其 stdin 写请求会触发 SIGPIPE，默认行为是杀掉整个 app。
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.colorScheme)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话") {
                    model.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.colorScheme)
        }
    }
}
