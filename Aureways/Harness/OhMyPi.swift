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

    /// Oh My Pi already maps `read`/`write`/`bash` onto ACP kinds. File tools
    /// use `path` (not `file_path`); move uses `oldPath`/`newPath`. Completed
    /// edits nest diffs under `rawOutput.details.perFileResults`.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.inferKind(from: Self.kindByName)
            patch.inferExecuteIfCommand()
            patch.aliasInput(from: ["cmd"], as: "command")
            patch.fillLocationsFromPath()
            patch.fillLocations(fromKeys: ["oldPath", "newPath"])
            patch.fillLocationsFromDiffs()
            patch.preferCommandTitle()
            patch.preferPathTitle()
            patch.promoteNestedDiffs()
            patch.canonicalizeOutput()
        }
    }

    private static let kindByName: [String: String] = [
        "read": "read",
        "write": "edit",
        "edit": "edit",
        "delete": "delete",
        "move": "move",
        "bash": "execute",
        "shell": "execute",
        "exec": "execute",
        "eval": "execute",
        "grep": "search",
        "glob": "search",
        "ast_grep": "search",
        "web_search": "fetch",
        "todo": "think",
    ]
}
