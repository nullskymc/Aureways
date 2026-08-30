import SwiftUI

@main
struct AurewaysApp: App {
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
