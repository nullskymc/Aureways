import Foundation

/// Google ships ACP as a separate binary (`agy_acp_server.par`), not `agy --acp`.
final class AntigravityHarness: Harness {
    static let id = "antigravity"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Antigravity",
                subtitle: "Google",
                command: "agy_acp_server",
                arguments: [],
                builtIn: true,
                notes: "需要已安装 Google 官方 Antigravity ACP（agy_acp_server.par）。agy CLI 没有 --acp。")
        )
    }

    override func launchCommand() -> String {
        Self.resolvedBinary() ?? "agy_acp_server"
    }

    override func isAvailable() -> Bool {
        Self.resolvedBinary() != nil
    }

    /// ACP defaults to the macOS Keychain. Quota reads `acp_token.json` instead
    /// of prompting Aureways for Keychain access, so force the file backend.
    override func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        if env["AGY_ACP_FORCE_FILE_STORAGE"] == nil {
            env["AGY_ACP_FORCE_FILE_STORAGE"] = "1"
        }
        return env
    }

    /// Prefer the real `.par` that sits next to `localharness_external`.
    /// A symlink of only the `.par` onto PATH fails at runtime.
    static func resolvedBinary() -> String? {
        let env = HostEnvironment.augmented()
        if let override = env["AGY_ACP_BIN"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let bundled = "\(NSHomeDirectory())/.local/share/antigravity-acp/agy_acp_server.par"
        if hasLocalHarness(beside: bundled) {
            return bundled
        }

        if let wrapper = HostEnvironment.resolveExecutable("agy_acp_server", environment: env) {
            return wrapper
        }

        if let par = HostEnvironment.resolveExecutable("agy_acp_server.par", environment: env),
           hasLocalHarness(beside: par) {
            return par
        }
        return nil
    }

    private static func hasLocalHarness(beside par: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: par) else { return false }
        let sibling = URL(fileURLWithPath: par)
            .deletingLastPathComponent()
            .appendingPathComponent("localharness_external")
            .path
        return FileManager.default.isExecutableFile(atPath: sibling)
    }

    /// Antigravity infers ACP `kind` from tool-name sets, but MCP dispatch
    /// (`call_mcp_tool`) is forced to `other` with a PascalCase envelope
    /// `{ServerName, ToolName, Arguments:{CommandLine, Cwd}}`. File tools use
    /// `TargetFile` / `target_file`. Exec output is `combinedOutput` + `exitCode`.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.applyCommonCodingAgentAliases(kindByName: Self.kindByName)
            patch.fillLocations(fromKeys: ["DirectoryPath", "directory_path", "SearchDirectory", "search_directory"])
        }
    }

    private static let kindByName: [String: String] = [
        "run_command": "execute",
        "shell": "execute",
        "client_view_file": "read",
        "view_file": "read",
        "read_file": "read",
        "client_create_file": "edit",
        "client_edit_file": "edit",
        "create_file": "edit",
        "edit_file": "edit",
        "write_file": "edit",
        "replace_file_content": "edit",
        "multi_replace_file_content": "edit",
        "write_to_file": "edit",
        "grep_search": "search",
        "find_by_name": "search",
        "list_dir": "search",
        "search_directory": "search",
        "list_directory": "search",
        "find_file": "search",
        "search_web": "search",
        "read_url_content": "fetch",
    ]
}
