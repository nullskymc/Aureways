import Foundation

final class CopilotHarness: Harness {
    static let id = "copilot"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "GitHub Copilot",
                subtitle: "GitHub",
                command: "copilot",
                arguments: ["--acp", "--stdio"],
                builtIn: true,
                notes: "需要已安装 Copilot 命令行工具。")
        )
    }
}
