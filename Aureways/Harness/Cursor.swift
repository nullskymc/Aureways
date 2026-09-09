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
    }

    /// Cursor's ACP adapter is closed-source. Same conservative aliases as
    /// Copilot: unwrap MCP envelopes and map common tool names onto `kind`.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.applyCommonCodingAgentAliases(kindByName: Self.kindByName)
        }
    }

    private static let kindByName: [String: String] = [
        "bash": "execute",
        "shell": "execute",
        "run_command": "execute",
        "read": "read",
        "read_file": "read",
        "write": "edit",
        "write_file": "edit",
        "edit": "edit",
        "edit_file": "edit",
        "grep": "search",
        "glob": "search",
    ]
}
