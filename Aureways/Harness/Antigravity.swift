import Foundation

/// Google replaced Gemini CLI with Antigravity CLI (`agy`).
final class AntigravityHarness: Harness {
    static let id = "antigravity"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Antigravity",
                subtitle: "Google",
                command: "agy",
                arguments: ["--acp"],
                builtIn: true,
                notes: "需要已安装 Antigravity CLI（agy）并完成登录。")
            )
        )
    }

    override func launchCommand() -> String {
        if HostEnvironment.resolveExecutable("agy") != nil {
            return "agy"
        }
        return "npx"
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        _ = autoApprove
        if HostEnvironment.resolveExecutable("agy") != nil {
            return ["--acp"]
        }
        return ["-y", "agy-acp"]
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("agy") != nil
            || HostEnvironment.resolveExecutable("npx") != nil
    }
}
