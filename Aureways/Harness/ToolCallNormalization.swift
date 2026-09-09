import Foundation

/// Shared pencil for rewriting a `tool_call` / `tool_call_update` JSON object.
///
/// Each harness decides *what* to rewrite. This type does not know any vendor's
/// tool names — it only aliases keys, unwraps envelopes, and fills spec fields
/// (`kind`, `title`, `locations`, `content`) once the harness has pointed at them.
struct ToolCallPatch {
    private var object: [String: JSONValue]

    static let genericTitles: Set<String> = [
        "tool", "tools",
        "execute", "exec", "terminal", "bash", "sh", "zsh", "shell", "run", "command",
        "run_command", "runcommand", "execute_command", "executecommand",
        "read", "read_file", "readfile", "view_file", "viewfile", "client_view_file",
        "edit", "edit_file", "editfile", "write", "write_file", "writefile",
        "client_edit_file", "client_create_file",
        "delete", "delete_file", "deletefile",
        "search", "grep", "grep_search", "find_by_name", "glob", "glob_search",
        "fetch", "web_search", "read_url_content", "call_mcp_tool", "webfetch",
    ]

    static func apply(_ json: JSONValue, _ body: (inout ToolCallPatch) -> Void) -> JSONValue {
        guard case .object(let object) = json else { return json }
        var patch = ToolCallPatch(object: object)
        body(&patch)
        return .object(patch.object)
    }

    var kind: String {
        object["kind"]?.stringValue ?? ""
    }

    var title: String {
        object["title"]?.stringValue ?? ""
    }

    var isKindMissingOrOther: Bool {
        let value = kind.lowercased()
        return value.isEmpty || value == "other"
    }

    var isGenericTitle: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        return Self.genericTitles.contains(lower) || lower == kind.lowercased()
    }

    mutating func aliasInput(from keys: [String], as key: String) {
        guard object["rawInput"]?[key] == nil else { return }
        if let value = inputValue(keys) {
            setInput(key, value)
        }
    }

    mutating func aliasOutput(from keys: [String], as key: String) {
        guard var output = object["rawOutput"]?.objectValue else { return }
        if output[key] != nil { return }
        for candidate in keys {
            if let value = output[candidate] {
                output[key] = value
                object["rawOutput"] = .object(output)
                return
            }
        }
    }

    /// Grok serializes `ToolInput` as `{ "variant": "ReadFile", "target_file": … }`.
    /// Lift a `path`/`command` alias from the tagged fields; keep `variant`.
    mutating func flattenTaggedInput() {
        guard let variant = inputString(["variant"]) else { return }
        switch variant {
        case "ReadFile", "CodexReadFile", "MemoryGet":
            aliasInput(from: ["target_file", "file_path", "path"], as: "path")
        case "SearchReplace", "Write", "HashlineEdit", "ApplyPatch":
            aliasInput(from: ["file_path", "path"], as: "path")
        case "ListDir", "CodexListDir":
            aliasInput(from: ["target_directory", "path"], as: "path")
        case "Bash":
            aliasInput(from: ["command"], as: "command")
        case "Grep", "CodexGrepFiles":
            aliasInput(from: ["path"], as: "path")
            aliasInput(from: ["pattern"], as: "pattern")
        case "WebFetch":
            aliasInput(from: ["url"], as: "url")
        case "WebSearch":
            aliasInput(from: ["query"], as: "query")
        default:
            aliasInput(from: ["target_file", "file_path", "target_directory", "path"], as: "path")
            aliasInput(from: ["command"], as: "command")
        }
    }

    mutating func setKind(fromVariant map: [String: String]) {
        guard isKindMissingOrOther, let variant = inputString(["variant"]) else { return }
        if let mapped = map[variant] {
            object["kind"] = .string(mapped)
        }
    }

    /// Antigravity MCP dispatch: `{ServerName, ToolName, Arguments:{…}}`.
    /// Codex MCP: `{server, tool, arguments:{…}}`.
    mutating func unwrapMcpEnvelope() {
        guard var input = object["rawInput"]?.objectValue else { return }
        let arguments = input["Arguments"] ?? input["arguments"]
        guard case .object(let inner) = arguments else { return }
        var next = inner
        if let tool = input["ToolName"] ?? input["toolName"] ?? input["tool"] {
            next["toolName"] = tool
        }
        if let server = input["ServerName"] ?? input["serverName"] ?? input["server"] {
            next["serverName"] = server
        }
        object["rawInput"] = .object(next)
        if isGenericTitle, let name = next["toolName"]?.stringValue, !name.isEmpty {
            object["title"] = .string(name)
        }
    }

    mutating func inferKind(from names: [String: String]) {
        guard isKindMissingOrOther else { return }
        var candidates: [String] = []
        if let tool = inputString(["toolName", "ToolName", "tool"]) {
            candidates.append(tool)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates.append(trimmed)
            if let prefix = trimmed.split(separator: ":", maxSplits: 1).first {
                candidates.append(String(prefix))
            }
            if let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).first {
                candidates.append(String(first))
            }
        }
        for candidate in candidates {
            let key = candidate.lowercased()
            if let mapped = names[key] ?? names[candidate] {
                object["kind"] = .string(mapped)
                return
            }
        }
    }

    mutating func inferExecuteIfCommand() {
        guard isKindMissingOrOther, let command = inputString(["command"]), !command.isEmpty else { return }
        if isGenericTitle || title.hasPrefix("$") {
            object["kind"] = .string("execute")
        }
    }

    /// OpenCode completed write/edit often omits `kind` and puts the path in `title`.
    mutating func inferEditFromWriteInput() {
        guard isKindMissingOrOther, inputString(["path"]) != nil else { return }
        if inputString(["content", "old_string", "oldString", "new_string", "newString"]) != nil {
            object["kind"] = .string("edit")
        }
    }

    mutating func fillLocationsFromPath(lineKeys: [String] = ["line", "offset", "Line", "StartLine"]) {
        guard let path = inputString(["path"]), !path.isEmpty else { return }
        if hasLocation(path: path) { return }
        var location: [String: JSONValue] = ["path": .string(path)]
        if let line = inputNumber(lineKeys), line > 0 {
            location["line"] = .number(Double(line))
        }
        appendLocation(.object(location))
    }

    mutating func fillLocations(fromKeys keys: [String]) {
        for key in keys {
            guard let path = inputString([key]), !path.isEmpty else { continue }
            if !hasLocation(path: path) {
                appendLocation(.object(["path": .string(path)]))
            }
        }
    }

    mutating func fillLocationsFromDiffs() {
        for item in object["content"]?.arrayValue ?? [] {
            guard item["type"]?.stringValue == "diff",
                  let path = item["path"]?.stringValue, !path.isEmpty
            else { continue }
            if !hasLocation(path: path) {
                appendLocation(.object(["path": .string(path)]))
            }
        }
    }

    mutating func preferCommandTitle() {
        guard isGenericTitle, let command = inputString(["command"]) else { return }
        let first = command.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !first.isEmpty {
            object["title"] = .string(first)
        }
    }

    mutating func preferPathTitle(verb: String? = nil) {
        guard isGenericTitle, let path = inputString(["path"]) else { return }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        guard !leaf.isEmpty else { return }
        let action = verb ?? pathTitleVerb()
        object["title"] = .string("\(action) \(leaf)")
    }

    /// OpenCode completed write/edit often puts the relative path in `title`.
    mutating func replacePathOnlyTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let path = inputString(["path"]) else { return }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        let isPathTitle = trimmed == path
            || trimmed == leaf
            || trimmed.hasSuffix("/" + leaf)
            || trimmed.hasSuffix(path)
        guard isPathTitle else { return }
        object["title"] = .string("\(pathTitleVerb()) \(leaf)")
    }

    /// Codex file-change events use a fixed "Editing files" title and no locations.
    mutating func rewriteEditingFilesTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() == "editing files" else { return }
        fillLocationsFromDiffs()
        let paths = (object["locations"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
        if paths.count == 1, let leaf = paths.first.map({ URL(fileURLWithPath: $0).lastPathComponent }), !leaf.isEmpty {
            object["title"] = .string("Edit \(leaf)")
        }
    }

    mutating func ensureDiffFromWriteInput() {
        let existing = object["content"]?.arrayValue ?? []
        if existing.contains(where: { $0["type"]?.stringValue == "diff" }) { return }
        guard kind.lowercased() == "edit" else { return }
        let path = inputString(["path"]) ?? ""
        guard let newText = inputString(["content", "new_string", "newString"]) else { return }
        let oldText = inputString(["old_string", "oldString"])
        var diff: [String: JSONValue] = [
            "type": .string("diff"),
            "path": .string(path),
            "newText": .string(newText),
        ]
        if let oldText {
            diff["oldText"] = .string(oldText)
        } else {
            diff["oldText"] = .null
        }
        var content = existing
        content.append(.object(diff))
        object["content"] = .array(content)
        if !path.isEmpty {
            fillLocationsFromPath()
        }
    }

    /// Oh My Pi completed edits put `{path, oldText, newText}` under `rawOutput.details`.
    mutating func promoteNestedDiffs() {
        let existing = object["content"]?.arrayValue ?? []
        if existing.contains(where: { $0["type"]?.stringValue == "diff" }) { return }
        let details = object["rawOutput"]?["details"]
        var rows: [JSONValue] = []
        if let perFile = details?["perFileResults"]?.arrayValue {
            rows = perFile
        } else if let details {
            rows = [details]
        }
        var diffs: [JSONValue] = []
        for row in rows {
            guard let path = row["path"]?.stringValue, !path.isEmpty else { continue }
            let oldText = row["oldText"]?.stringValue
            let newText = row["newText"]?.stringValue
            guard oldText != nil || newText != nil else { continue }
            diffs.append(.object([
                "type": .string("diff"),
                "path": .string(path),
                "oldText": oldText.map(JSONValue.string) ?? .null,
                "newText": .string(newText ?? ""),
            ]))
            if !hasLocation(path: path) {
                appendLocation(.object(["path": .string(path)]))
            }
        }
        if !diffs.isEmpty {
            object["content"] = .array(existing + diffs)
        }
    }

    mutating func canonicalizeOutput() {
        aliasOutput(from: ["formatted_output", "combinedOutput", "combined_output", "stdout"], as: "output")
        aliasOutput(from: ["exit_code", "returncode"], as: "exitCode")
    }

    mutating func applyCommonCodingAgentAliases(kindByName: [String: String]) {
        unwrapMcpEnvelope()
        aliasInput(from: ["CommandLine", "command_line", "commandLine", "cmd", "cmdLine", "cmd_line"], as: "command")
        aliasInput(from: ["working_dir", "workingDir", "workingDirectory", "Cwd", "workdir", "dir"], as: "cwd")
        aliasInput(
            from: ["TargetFile", "target_file", "FilePath", "file_path", "filePath", "filepath", "AbsolutePath", "absolute_path"],
            as: "path"
        )
        inferKind(from: kindByName)
        inferExecuteIfCommand()
        fillLocationsFromPath()
        fillLocationsFromDiffs()
        preferCommandTitle()
        preferPathTitle()
        replacePathOnlyTitle()
        canonicalizeOutput()
    }

    private func pathTitleVerb() -> String {
        switch kind.lowercased() {
        case "read": return "Read"
        case "edit": return "Edit"
        case "delete": return "Delete"
        case "move": return "Move"
        default: return "File"
        }
    }

    func inputString(_ keys: [String]) -> String? {
        guard let value = inputValue(keys) else { return nil }
        if let string = value.stringValue {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func inputNumber(_ keys: [String]) -> Int? {
        guard let value = inputValue(keys), let number = value.int64Value else { return nil }
        return Int(number)
    }

    private func inputValue(_ keys: [String]) -> JSONValue? {
        guard let input = object["rawInput"] else { return nil }
        for key in keys {
            if let value = input[key] { return value }
        }
        return nil
    }

    private mutating func setInput(_ key: String, _ value: JSONValue) {
        var input = object["rawInput"]?.objectValue ?? [:]
        input[key] = value
        object["rawInput"] = .object(input)
    }

    private func hasLocation(path: String) -> Bool {
        (object["locations"]?.arrayValue ?? []).contains { $0["path"]?.stringValue == path }
    }

    private mutating func appendLocation(_ location: JSONValue) {
        var locations = object["locations"]?.arrayValue ?? []
        locations.append(location)
        object["locations"] = .array(locations)
    }
}
