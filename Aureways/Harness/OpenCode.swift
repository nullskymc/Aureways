import Foundation

final class OpenCodeHarness: Harness {
    static let id = "opencode"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "OpenCode",
                subtitle: "opencode acp",
                command: "opencode",
                arguments: ["acp"],
                builtIn: true,
                notes: "OpenCode ACP server, if installed."
            )
        )
    }
}
