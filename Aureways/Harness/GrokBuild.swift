import Foundation

final class GrokBuildHarness: Harness {
    static let id = "grok-build"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Grok Build",
                subtitle: "xAI",
                command: "grok",
                arguments: ["agent", "stdio"],
                builtIn: true,
                notes: "需要已安装 grok 命令行工具并完成登录。")
        )
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        if autoApprove {
            return ["agent", "--always-approve", "stdio"]
        }
        return ["agent", "stdio"]
    }

    override func sessionMeta(autoApprove: Bool) -> [String: JSONValue]? {
        autoApprove ? ["yoloMode": .bool(true)] : nil
    }

    /// Grok packs an entire shell line into `terminal/create`'s `command` and
    /// sends no `args` — ACP reserves `command` for the program name, so the
    /// request used to fail with "the file `bash -lc '…'` doesn't exist".
    ///
    /// Route it through the login shell explicitly here rather than leaning on
    /// the client's generic PATH-lookup fallback. For an agent that *always*
    /// sends shell lines, that is both deterministic and more correct: builtins,
    /// pipes and redirects work whether or not the first token happens to be a
    /// program on PATH (`cd foo && ls` works; so does a bare `ls`).
    ///
    /// A request that already carries `args` is left alone — that shape is
    /// well-formed and means the agent really did mean a program name.
    override func normalizeClientRequest(method: String, params: JSONValue) -> JSONValue {
        guard method == "terminal/create",
              var object = params.objectValue,
              let line = object["command"]?.stringValue,
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (object["args"]?.arrayValue ?? []).isEmpty
        else { return params }
        object["command"] = .string(Self.loginShell)
        object["args"] = .array([.string("-lc"), .string(line)])
        return .object(object)
    }

    private static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
