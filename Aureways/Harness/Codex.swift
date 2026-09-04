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
                notes: "需要 Node.js。使用本机已有的 Codex 登录。")
            )
        )
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("npx") != nil
    }
}
