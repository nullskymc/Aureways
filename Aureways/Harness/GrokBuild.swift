import Foundation

final class GrokBuildHarness: Harness {
    static let id = "grok-build"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Grok Build",
                subtitle: "xAI Grok agent over ACP stdio",
                command: "grok",
                arguments: ["agent", "stdio"],
                builtIn: true,
                notes: "Requires an installed grok CLI and a completed login."
            )
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
