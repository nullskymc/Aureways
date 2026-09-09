import Foundation

final class CodexHarness: Harness {
    static let id = "codex"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Codex",
                subtitle: "OpenAI",
                command: "npx",
                arguments: ["-y", "@agentclientprotocol/codex-acp"],
                builtIn: true,
                notes: "需要 Node.js。登录、API Key 和三方供应商都在 Codex 自己的配置里（~/.codex），Aureways 不代填。")
        )
    }

    override func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable("npx") != nil
    }

    /// File-change events ship diffs in `content` but no `locations` / `rawInput`,
    /// and a fixed title "Editing files". Shell completion uses
    /// `formatted_output` + `exit_code`. MCP calls wrap `{server, tool, arguments}`.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.unwrapMcpEnvelope()
            patch.aliasInput(from: ["cmd"], as: "command")
            patch.aliasInput(from: ["workdir"], as: "cwd")
            patch.fillLocationsFromDiffs()
            patch.fillLocationsFromPath()
            patch.rewriteEditingFilesTitle()
            patch.inferKind(from: Self.kindByName)
            patch.inferExecuteIfCommand()
            patch.preferCommandTitle()
            patch.canonicalizeOutput()
        }
    }

    private static let kindByName: [String: String] = [
        "exec_command": "execute",
        "apply_patch": "edit",
        "view_image": "read",
    ]
}
