import Foundation

final class CodexHarness: Harness {
    static let id = "codex"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Codex",
                subtitle: "OpenAI Codex via @agentclientprotocol/codex-acp",
                command: "npx",
                arguments: ["-y", "@agentclientprotocol/codex-acp"],
                builtIn: true,
                notes: "Needs Node.js. Uses the Codex CLI authentication already on this Mac."
            )
        )
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("npx") != nil
    }
}
