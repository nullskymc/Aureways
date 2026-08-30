import Foundation

final class CopilotHarness: Harness {
    static let id = "copilot"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "GitHub Copilot",
                subtitle: "copilot --acp --stdio",
                command: "copilot",
                arguments: ["--acp", "--stdio"],
                builtIn: true,
                notes: "Copilot CLI public preview ACP mode."
            )
        )
    }
}
