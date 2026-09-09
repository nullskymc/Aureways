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
}
