import Foundation

final class ClaudeCodeHarness: Harness {
    static let id = "claude"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Claude Code",
                subtitle: "Anthropic",
                command: "npx",
                arguments: ["-y", "@agentclientprotocol/claude-agent-acp"],
                builtIn: true,
                notes: "需要 Node.js，以及可用的 claude 命令行登录。")
        )
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("npx") != nil
    }

    /// Claude already sends spec `kind` / `title` / `locations` / diffs.
    /// `rawInput` uses `file_path` rather than `path`.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.aliasInput(from: ["file_path"], as: "path")
            patch.fillLocationsFromPath(lineKeys: ["offset", "line"])
            patch.fillLocationsFromDiffs()
            patch.canonicalizeOutput()
        }
    }
}
