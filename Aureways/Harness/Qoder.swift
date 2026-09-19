import Foundation

/// Qoder CLI (`qoder` or `qoderclicn`) speaks ACP natively: `qoder --acp` /
/// `qoderclicn --acp` is a stdio JSON-RPC server. `--acp` is undocumented
/// but advertised in `initialize` (protocolVersion 1, `loadSession`, image input).
final class QoderHarness: Harness {
    static let id = "qoder"

    init() {
        let binary = Self.resolvedBinary() ?? "qoder"
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Qoder",
                subtitle: "Qoder",
                command: binary,
                arguments: ["--acp"],
                builtIn: true,
                notes: "需要已安装 Qoder CLI（qoder 或 qoderclicn）并执行登录。支持国际版与国内版。")
        )
    }

    override func launchCommand() -> String {
        Self.resolvedBinary() ?? profile.command
    }

    override func isAvailable() -> Bool {
        Self.resolvedBinary() != nil
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        autoApprove ? ["--acp", "--yolo"] : ["--acp"]
    }

    static func resolvedBinary() -> String? {
        let env = HostEnvironment.augmented()
        if HostEnvironment.resolveExecutable("qoder", environment: env) != nil {
            return "qoder"
        }
        if HostEnvironment.resolveExecutable("qoderclicn", environment: env) != nil {
            return "qoderclicn"
        }
        return nil
    }
}
