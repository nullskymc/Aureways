import Foundation

struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var command: String
    var arguments: [String]
    var builtIn: Bool
    var notes: String

    var launchLine: String {
        ([command] + arguments).joined(separator: " ")
    }
}

/// Shared ACP stdio launch recipe. Each vendor subclasses this file's type
/// so command line, env, availability, and session `_meta` stay in one place.
///
/// Immutable after construction (`profile` is the only stored property), hence
/// the unchecked conformance — a harness is handed to the connection actor so
/// it can normalize incoming requests off the main actor.
class Harness: @unchecked Sendable {
    let profile: AgentProfile

    var id: String { profile.id }

    init(profile: AgentProfile) {
        self.profile = profile
    }

    func launchCommand() -> String {
        profile.command
    }

    func launchArguments(autoApprove: Bool) -> [String] {
        _ = autoApprove
        return profile.arguments
    }

    func environment(_ base: [String: String]) -> [String: String] {
        base
    }

    func sessionMeta(autoApprove: Bool) -> [String: JSONValue]? {
        _ = autoApprove
        return nil
    }

    /// Rewrite an agent → client request before the client handles it.
    ///
    /// Agents deviate from ACP in small ways that only the client can absorb —
    /// we do not get to fix the agent. Keeping the corrections on the harness
    /// rather than in `ACPConnection` means each one stays attributable to the
    /// agent that needs it, and the protocol layer stays a straight reading of
    /// the spec. Default is a no-op.
    func normalizeClientRequest(method: String, params: JSONValue) -> JSONValue {
        _ = method
        return params
    }

    func isAvailable() -> Bool {
        HostEnvironment.resolveExecutable(launchCommand()) != nil
    }

    @MainActor
    func makeRuntime() -> HarnessRuntime {
        HarnessRuntime(harness: self)
    }
}

enum HarnessRegistry {
    static var builtIn: [Harness] {
        [
            GrokBuildHarness(),
            CodexHarness(),
            ClaudeCodeHarness(),
            AntigravityHarness(),
            CopilotHarness(),
            CursorHarness(),
            OpenCodeHarness(),
        ]
    }

    static func resolve(_ profile: AgentProfile) -> Harness {
        if let match = builtIn.first(where: { $0.id == profile.id }) {
            return match
        }
        return CustomHarness(profile: profile)
    }

    static func migrateAgentId(_ id: String) -> String {
        switch id {
        case "gemini":
            return AntigravityHarness.id
        default:
            return id
        }
    }
}

enum AgentCatalog {
    static var builtIn: [AgentProfile] {
        HarnessRegistry.builtIn.map(\.profile)
    }

    static func custom(title: String, commandLine: String) -> AgentProfile? {
        CustomHarness.profile(title: title, commandLine: commandLine)
    }

    static func splitCommandLine(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

enum HostEnvironment {
    static func augmented() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.volta/bin",
            "\(NSHomeDirectory())/.fnm",
            "/usr/bin",
            "/bin",
        ]
        let path = env["PATH"] ?? ""
        let merged = extras + path.split(separator: ":").map(String.init)
        var seen = Set<String>()
        let unique = merged.filter { seen.insert($0).inserted }
        env["PATH"] = unique.joined(separator: ":")
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        return env
    }

    static func resolveExecutable(_ command: String, environment: [String: String]? = nil) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        let env = environment ?? augmented()
        let path = env["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isAvailable(_ profile: AgentProfile) -> Bool {
        HarnessRegistry.resolve(profile).isAvailable()
    }
}
