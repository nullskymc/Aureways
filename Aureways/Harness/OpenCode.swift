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
    }

    /// OpenCode uses camelCase (`filePath`, `oldString`, `workdir`). Pending
    /// titles are the tool name (`read` / `write` / `bash`); completed write
    /// titles become the relative path. Shell `rawInput` may omit `cwd` until
    /// the adapter fills `workdir`.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.aliasInput(from: ["filePath", "filepath"], as: "path")
            patch.aliasInput(from: ["workdir"], as: "cwd")
            patch.aliasInput(from: ["cmd"], as: "command")
            patch.inferKind(from: Self.kindByName)
            patch.inferEditFromWriteInput()
            patch.inferExecuteIfCommand()
            patch.fillLocationsFromPath()
            patch.fillLocationsFromDiffs()
            patch.preferCommandTitle()
            patch.preferPathTitle()
            patch.replacePathOnlyTitle()
            patch.ensureDiffFromWriteInput()
            patch.canonicalizeOutput()
        }
    }

    private static let kindByName: [String: String] = [
        "bash": "execute",
        "shell": "execute",
        "read": "read",
        "write": "edit",
        "edit": "edit",
        "apply_patch": "edit",
        "patch": "edit",
        "grep": "search",
        "glob": "search",
        "webfetch": "fetch",
        "task": "think",
    ]
}
