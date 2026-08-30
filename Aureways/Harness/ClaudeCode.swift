import Foundation

final class ClaudeCodeHarness: Harness {
    static let id = "claude"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Claude Code",
                subtitle: "Claude Agent SDK via claude-agent-acp",
                command: "npx",
                arguments: ["-y", "@agentclientprotocol/claude-agent-acp"],
                builtIn: true,
                notes: "Needs Node.js and a working claude CLI login."
            )
        )
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("npx") != nil
    }
}
