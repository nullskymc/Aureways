import Foundation

final class CodexHarness: Harness {
    static let id = "codex"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Codex",
                subtitle: "OpenAI",
                command: "npx",
                arguments: ["-y", "@agentclientprotocol/codex-acp"],
                builtIn: true,
                notes: "需要 Node.js。登录、API Key 和三方供应商都在 Codex 自己的配置里（~/.codex），Aureways 不代填。")
        )
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("npx") != nil
    }
}
