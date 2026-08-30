import Foundation

final class CursorHarness: Harness {
    static let id = "cursor"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Cursor Agent",
                subtitle: "cursor-agent acp",
                command: "cursor-agent",
                arguments: ["acp"],
                builtIn: true,
                notes: "Uses the Cursor CLI ACP server."
            )
        )
    }
}
