import SwiftUI

@main
struct AurewaysApp: App {
    @State private var model = AppModel()

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
                Button("New Session") {
                    if let agent = model.agents.first(where: { model.availability[$0.id] == true }) {
                        model.startSession(agent)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.colorScheme)
                .frame(width: 500, height: 380)
        }
    }
}
