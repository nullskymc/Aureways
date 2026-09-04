import Foundation

final class CursorHarness: Harness {
    static let id = "cursor"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Cursor Agent",
                subtitle: "Cursor",
                command: "cursor-agent",
                arguments: ["acp"],
                builtIn: true,
                notes: "需要已安装 Cursor 命令行工具。")
            )
        )
    }
}
