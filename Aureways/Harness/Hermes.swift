import Foundation

/// Hermes Agent speaks ACP on stdio: `hermes acp`, or the `hermes-acp` entry
/// point when the `hermes` launcher is not on PATH. Logs stay on stderr.
///
/// Polished tools (`read_file`, `write_file`, `patch`, `terminal`, `search_files`,
/// web tools) already set `kind`, `locations`, and diff `content`, but omit
/// `rawInput`. Titles carry the missing field (`terminal: git status`,
/// `search: TODO`, `read: src/a.ts`). Session approval is an ACP mode
/// (`default` / `accept_edits` / `dont_ask`), not a launch flag.
final class HermesHarness: Harness {
    static let id = "hermes"

    init() {
        let launch = Self.resolvedLaunch()
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Hermes",
                subtitle: "Nous Research",
                command: launch?.command ?? "hermes",
                arguments: launch?.arguments ?? ["acp"],
                builtIn: true,
                notes: "需要已安装 Hermes Agent（hermes 或 hermes-acp）。在终端运行 hermes model 配置模型和供应商。"
            )
        )
    }

    override func launchCommand() -> String {
        Self.resolvedLaunch()?.command ?? profile.command
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        _ = autoApprove
        return Self.resolvedLaunch()?.arguments ?? profile.arguments
    }

    override func isAvailable() -> Bool {
        Self.resolvedLaunch() != nil
    }

    /// Prefer `hermes acp`. `hermes-acp` is the same server with no subcommand.
    static func resolvedLaunch() -> (command: String, arguments: [String])? {
        let env = HostEnvironment.augmented()
        if HostEnvironment.resolveExecutable("hermes", environment: env) != nil {
            return ("hermes", ["acp"])
        }
        if HostEnvironment.resolveExecutable("hermes-acp", environment: env) != nil {
            return ("hermes-acp", [])
        }
        return nil
    }

    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        let seeded = Self.seedRawInput(fromTitle: json)
        let patched = ToolCallPatch.apply(seeded) { patch in
            patch.fillLocationsFromPath()
            patch.canonicalizeOutput()
        }
        return patched.mapObject { object in
            // Browser and delegate tools are `execute` with no shell command.
            // Leaving that kind makes the row title the generic “命令”.
            let kind = object["kind"]?.stringValue?.lowercased() ?? ""
            guard kind == "execute" || kind == "terminal" || kind == "shell" else { return }
            let command = object["rawInput"]?["command"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if command.isEmpty {
                object["kind"] = .string("other")
            }
        }
    }

    /// Hermes `build_tool_title` prefixes. `?` is the adapter's placeholder
    /// for a missing argument and is not a real value.
    private static let titleFields: [(prefix: String, key: String)] = [
        ("terminal: ", "command"),
        ("python: ", "command"),
        ("process ", "command"),
        ("search: ", "pattern"),
        ("web search: ", "url"),
        ("extract: ", "url"),
        ("navigate: ", "url"),
        ("read: ", "path"),
        ("write: ", "path"),
    ]

    private static func seedRawInput(fromTitle json: JSONValue) -> JSONValue {
        json.mapObject { object in
            let title = object["title"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return }
            var input = object["rawInput"]?.objectValue ?? [:]
            var changed = false
            if title.hasPrefix("patch ("), let marker = title.range(of: "): ") {
                let path = String(title[marker.upperBound...])
                if assign(&input, key: "path", value: path) { changed = true }
            } else {
                for field in titleFields where title.hasPrefix(field.prefix) {
                    let value = String(title.dropFirst(field.prefix.count))
                    if assign(&input, key: field.key, value: value) { changed = true }
                    break
                }
            }
            if changed {
                object["rawInput"] = .object(input)
            }
        }
    }

    private static func assign(
        _ input: inout [String: JSONValue],
        key: String,
        value: String
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "?" else { return false }
        if let existing = input[key]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return false
        }
        input[key] = .string(trimmed)
        return true
    }
}
