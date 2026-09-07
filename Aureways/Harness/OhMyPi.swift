import Foundation

/// Oh My Pi (`omp`) speaks ACP natively: `omp acp` is a stdio JSON-RPC server.
final class OhMyPiHarness: Harness {
    static let id = "oh-my-pi"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Oh My Pi",
                subtitle: "Oh My Pi",
                command: "omp",
                arguments: ["acp"],
                builtIn: true,
                notes: "需要已安装 Oh My Pi（omp）与 Bun。登录和模型在 omp 自己的配置里。")
        )
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        autoApprove ? ["acp", "--yolo"] : ["acp"]
    }
}
