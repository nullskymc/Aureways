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

enum AgentCatalog {
    static let builtIn: [AgentProfile] = [
        AgentProfile(
            id: "grok-build",
            title: "Grok Build",
            subtitle: "xAI Grok agent over ACP stdio",
            command: "grok",
            arguments: ["agent", "stdio"],
            builtIn: true,
            notes: "Requires an installed grok CLI and a completed login."
        ),
        AgentProfile(
            id: "codex",
            title: "Codex",
            subtitle: "OpenAI Codex via @agentclientprotocol/codex-acp",
            command: "npx",
            arguments: ["-y", "@agentclientprotocol/codex-acp"],
            builtIn: true,
            notes: "Needs Node.js. Uses the Codex CLI authentication already on this Mac."
        ),
        AgentProfile(
            id: "claude",
            title: "Claude Code",
            subtitle: "Claude Agent SDK via claude-agent-acp",
            command: "npx",
            arguments: ["-y", "@agentclientprotocol/claude-agent-acp"],
            builtIn: true,
            notes: "Needs Node.js and a working claude CLI login."
        ),
        AgentProfile(
            id: "gemini",
            title: "Gemini CLI",
            subtitle: "gemini --acp",
            command: "gemini",
            arguments: ["--acp"],
            builtIn: true,
            notes: "Install Google Gemini CLI and authenticate first."
        ),
        AgentProfile(
            id: "copilot",
            title: "GitHub Copilot",
            subtitle: "copilot --acp --stdio",
            command: "copilot",
            arguments: ["--acp", "--stdio"],
            builtIn: true,
            notes: "Copilot CLI public preview ACP mode."
        ),
        AgentProfile(
            id: "cursor",
            title: "Cursor Agent",
            subtitle: "cursor-agent acp",
            command: "cursor-agent",
            arguments: ["acp"],
            builtIn: true,
            notes: "Uses the Cursor CLI ACP server."
        ),
        AgentProfile(
            id: "opencode",
            title: "OpenCode",
            subtitle: "opencode acp",
            command: "opencode",
            arguments: ["acp"],
            builtIn: true,
            notes: "OpenCode ACP server, if installed."
        ),
    ]

    static func custom(title: String, commandLine: String) -> AgentProfile? {
        let parts = splitCommandLine(commandLine)
        guard let command = parts.first, !command.isEmpty else { return nil }
        return AgentProfile(
            id: "custom-\(UUID().uuidString.lowercased())",
            title: title.isEmpty ? command : title,
            subtitle: commandLine,
            command: command,
            arguments: Array(parts.dropFirst()),
            builtIn: false,
            notes: "User-defined ACP agent."
        )
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
        resolveExecutable(profile.command) != nil
    }
}
