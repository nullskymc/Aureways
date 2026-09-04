import Foundation

final class OpenCodeHarness: Harness {
    static let id = "opencode"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "OpenCode",
                subtitle: "OpenCode",
                command: "opencode",
                arguments: ["acp"],
                builtIn: true,
                notes: "需要本机已安装 OpenCode。")
            )
        )
    }
}
