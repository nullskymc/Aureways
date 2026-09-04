import Foundation

final class GrokBuildHarness: Harness {
    static let id = "grok-build"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Grok Build",
                subtitle: "xAI",
                command: "grok",
                arguments: ["agent", "stdio"],
                builtIn: true,
                notes: "需要已安装 grok 命令行工具并完成登录。")
        )
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        if autoApprove {
            return ["agent", "--always-approve", "stdio"]
        }
        return ["agent", "stdio"]
    }

    override func sessionMeta(autoApprove: Bool) -> [String: JSONValue]? {
        autoApprove ? ["yoloMode": .bool(true)] : nil
    }
}
