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

    /// Copilot's ACP adapter is closed-source. Alias the common PascalCase /
    /// snake_case tool-call keys so the card can still pick out path and command.
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
        "view_file": "read",
        "write": "edit",
        "write_file": "edit",
        "edit": "edit",
        "edit_file": "edit",
        "grep": "search",
        "glob": "search",
    ]
}
