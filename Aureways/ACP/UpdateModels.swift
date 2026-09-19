import Foundation

enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String, uri: String?)
    case audio(data: String, mimeType: String)
    case resourceLink(uri: String, name: String)
    case resource(uri: String, mimeType: String?, text: String?, blob: String?)
    case other(JSONValue)

    var text: String? {
        switch self {
        case .text(let value): return value
        case .resource(_, _, let text, _): return text
        case .other(let json): return json["text"]?.stringValue ?? json["resource"]?["text"]?.stringValue
        default: return nil
        }
    }

    func concatenating(_ other: ContentBlock) -> ContentBlock? {
        var copy = self
        guard copy.consumeAppend(other) else { return nil }
        return copy
    }

    /// Drops `self`'s reference before appending so CoW does not copy the
    /// accumulated buffer on every pulse merge.
    mutating func consumeAppend(_ other: ContentBlock) -> Bool {
        guard case .text(var left) = self, case .text(let right) = other else { return false }
        self = .text("")
        left.reserveCapacity(left.count + right.count)
        left.append(right)
        self = .text(left)
        return true
    }

    init(json: JSONValue) {
        if let str = json.stringValue {
            self = .text(str)
            return
        }
        let type = json["type"]?.stringValue
        switch type {
        case "text":
            if let text = json["text"]?.stringValue {
                self = .text(text)
                return
            }
        case "image":
            let data = json["data"]?.stringValue
                ?? json["source"]?["data"]?.stringValue
            let uri = json["uri"]?.stringValue
                ?? json["url"]?.stringValue
                ?? json["path"]?.stringValue
            let mimeType = json["mimeType"]?.stringValue
                ?? json["mediaType"]?.stringValue
                ?? json["source"]?["media_type"]?.stringValue
                ?? "image/png"
            if let data, !data.isEmpty {
                self = .image(data: data, mimeType: mimeType, uri: uri)
                return
            } else if let uri, !uri.isEmpty {
                self = .image(data: "", mimeType: mimeType, uri: uri)
                return
            }
        case "audio":
            if let data = json["data"]?.stringValue, !data.isEmpty {
                self = .audio(
                    data: data,
                    mimeType: json["mimeType"]?.stringValue ?? "audio/wav"
                )
                return
            }
        case "image_url":
            let url = json["image_url"]?["url"]?.stringValue
                ?? json["image_url"]?.stringValue
                ?? json["url"]?.stringValue
            if let url, !url.isEmpty {
                if url.hasPrefix("data:") {
                    let parts = url.dropFirst(5).components(separatedBy: ";base64,")
                    if parts.count == 2 {
                        self = .image(data: parts[1], mimeType: parts[0], uri: nil)
                        return
                    }
                }
                self = .image(data: "", mimeType: "image/png", uri: url)
                return
            }
        case "resource_link":
            if let uri = json["uri"]?.stringValue {
                self = .resourceLink(uri: uri, name: json["name"]?.stringValue ?? uri)
                return
            }
        case "resource":
            let resource = json["resource"]
            let uri = resource?["uri"]?.stringValue ?? json["uri"]?.stringValue
            let mimeType = resource?["mimeType"]?.stringValue ?? json["mimeType"]?.stringValue
            let text = resource?["text"]?.stringValue
            let blob = resource?["blob"]?.stringValue
            if let text, !text.isEmpty {
                self = .resource(uri: uri ?? "", mimeType: mimeType, text: text, blob: nil)
                return
            }
            if let blob, !blob.isEmpty {
                if (mimeType ?? "").hasPrefix("image/") {
                    self = .image(data: blob, mimeType: mimeType ?? "image/png", uri: uri)
                } else {
                    self = .resource(uri: uri ?? "", mimeType: mimeType, text: nil, blob: blob)
                }
                return
            }
            if let uri, !uri.isEmpty {
                self = .resourceLink(uri: uri, name: json["name"]?.stringValue ?? uri)
                return
            }
        default:
            if let text = json["text"]?.stringValue {
                self = .text(text)
                return
            }
        }
        self = .other(json)
    }

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        self.init(json: json)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            try JSONValue.object([
                "type": .string("text"),
                "text": .string(text),
            ]).encode(to: encoder)
        case .image(let data, let mimeType, let uri):
            var object: [String: JSONValue] = [
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType),
            ]
            if let uri { object["uri"] = .string(uri) }
            try JSONValue.object(object).encode(to: encoder)
        case .audio(let data, let mimeType):
            try JSONValue.object([
                "type": .string("audio"),
                "data": .string(data),
                "mimeType": .string(mimeType),
            ]).encode(to: encoder)
        case .resourceLink(let uri, let name):
            try JSONValue.object([
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name),
            ]).encode(to: encoder)
        case .resource(let uri, let mimeType, let text, let blob):
            var resource: [String: JSONValue] = ["uri": .string(uri)]
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            if let text { resource["text"] = .string(text) }
            if let blob { resource["blob"] = .string(blob) }
            try JSONValue.object([
                "type": .string("resource"),
                "resource": .object(resource),
            ]).encode(to: encoder)
        case .other(let json):
            try json.encode(to: encoder)
        }
    }
}

enum SessionUpdate: Sendable, Equatable {
    case userMessageChunk(ContentBlock)
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case toolCall(ToolCallView)
    case toolCallUpdate(ToolCallView)
    case plan([PlanEntry])
    case availableCommands([SlashCommand])
    case currentMode(String)
    case sessionInfo(String)
    case configOption(String, JSONValue)
    case configOptions([SessionConfigOption])
    case modelChanged(String, String?)
    case usage(SessionUsage)
    case unknown(String, JSONValue)

    init(json: JSONValue) {
        let kind = json["sessionUpdate"]?.stringValue ?? "unknown"
        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(Self.decodeContent(json["content"]))
        case "agent_message_chunk":
            self = .agentMessageChunk(Self.decodeContent(json["content"]))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(Self.decodeContent(json["content"]))
        case "tool_call":
            self = .toolCall(ToolCallView(json: json))
        case "tool_call_update":
            self = .toolCallUpdate(ToolCallView(json: json))
        case "plan":
            let entries = json["entries"]?.arrayValue?.compactMap(PlanEntry.init) ?? []
            self = .plan(entries)
        case "available_commands_update":
            let commands = json["availableCommands"]?.arrayValue?.compactMap(SlashCommand.init) ?? []
            self = .availableCommands(commands)
        case "current_mode_update":
            self = .currentMode(json["currentModeId"]?.stringValue ?? json["modeId"]?.stringValue ?? "")
        case "session_info_update":
            self = .sessionInfo(json["title"]?.stringValue ?? json["sessionTitle"]?.stringValue ?? "")
        case "config_option_update":
            if let items = json["configOptions"]?.arrayValue {
                let options = items.compactMap(SessionConfigOption.init(json:))
                if !options.isEmpty {
                    self = .configOptions(options)
                    return
                }
            }
            let id = json["configId"]?.stringValue ?? json["id"]?.stringValue ?? json["configOption"]?["id"]?.stringValue ?? ""
            let value = SessionConfigOption.scalarValue(json["value"] ?? json["configOption"]?["value"]) ?? .null
            self = .configOption(id, value)
        case "model_changed":
            let modelId = json["model_id"]?.stringValue ?? json["modelId"]?.stringValue ?? ""
            let effort = json["reasoning_effort"]?.stringValue ?? json["reasoningEffort"]?.stringValue
            self = .modelChanged(modelId, effort)
        case "usage_update":
            if let usage = SessionUsage(json: json) {
                self = .usage(usage)
            } else {
                self = .unknown(kind, json)
            }
        default:
            self = .unknown(kind, json)
        }
    }

    private static func decodeContent(_ json: JSONValue?) -> ContentBlock {
        guard let json else { return .text("") }
        if let array = json.arrayValue, let first = array.first {
            return ContentBlock(json: first)
        }
        return ContentBlock(json: json)
    }
}

struct SessionNotification: Sendable, Equatable {
    var sessionId: String
    var messageId: String?
    var update: SessionUpdate

    init(sessionId: String, update: SessionUpdate, messageId: String? = nil) {
        self.sessionId = sessionId
        self.update = update
        self.messageId = messageId
    }

    init?(json: JSONValue) {
        guard let sessionId = json["sessionId"]?.stringValue else { return nil }
        self.sessionId = sessionId
        self.messageId = json["update"]?["messageId"]?.stringValue ?? json["messageId"]?.stringValue
        self.update = SessionUpdate(json: json["update"] ?? .null)
    }

    func merging(_ next: SessionNotification) -> SessionNotification? {
        var copy = self
        guard copy.absorb(next) else { return nil }
        return copy
    }

    /// Consumes `self` then appends `next` in place. Caller must uniquely own
    /// `self` (e.g. via `popLast()`) or CoW still copies.
    mutating func absorb(_ next: SessionNotification) -> Bool {
        guard sessionId == next.sessionId else { return false }
        switch (update, next.update) {
        case (.agentMessageChunk(var left), .agentMessageChunk(let right)):
            guard case .text = left, case .text = right else { return false }
            update = .agentMessageChunk(.text(""))
            guard left.consumeAppend(right) else { return false }
            update = .agentMessageChunk(left)
        case (.agentThoughtChunk(var left), .agentThoughtChunk(let right)):
            guard case .text = left, case .text = right else { return false }
            update = .agentThoughtChunk(.text(""))
            guard left.consumeAppend(right) else { return false }
            update = .agentThoughtChunk(left)
        case (.userMessageChunk(var left), .userMessageChunk(let right)):
            guard case .text = left, case .text = right else { return false }
            update = .userMessageChunk(.text(""))
            guard left.consumeAppend(right) else { return false }
            update = .userMessageChunk(left)
        case (.toolCallUpdate(var left), .toolCallUpdate(let right)) where left.toolCallId == right.toolCallId:
            left.merge(right)
            update = .toolCallUpdate(left)
        case (.usage, .usage), (.availableCommands, .availableCommands), (.sessionInfo, .sessionInfo):
            update = next.update
        default:
            return false
        }
        messageId = next.messageId ?? messageId
        return true
    }

    static func coalesced(_ notes: [SessionNotification]) -> [SessionNotification] {
        var result: [SessionNotification] = []
        result.reserveCapacity(notes.count)
        for note in notes {
            if var last = result.popLast() {
                if last.absorb(note) {
                    result.append(last)
                    continue
                }
                result.append(last)
            }
            result.append(note)
        }
        return result
    }
}

struct ToolCallLocation: Sendable, Equatable {
    var path: String
    var line: Int?

    init?(json: JSONValue) {
        guard let path = json["path"]?.stringValue, !path.isEmpty else { return nil }
        self.path = path
        line = json["line"]?.int64Value.map(Int.init)
    }
}

enum ToolCallContentItem: Sendable, Equatable {
    case text(String)
    case diff(path: String, oldText: String?, newText: String?)
    case terminal(String)

    init?(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "diff":
            let path = json["path"]?.stringValue ?? ""
            self = .diff(path: path, oldText: json["oldText"]?.stringValue, newText: json["newText"]?.stringValue)
        case "terminal":
            guard let id = json["terminalId"]?.stringValue, !id.isEmpty else { return nil }
            self = .terminal(id)
        case "content":
            let inner = json["content"]
            if let text = inner?["text"]?.stringValue {
                self = .text(text)
            } else {
                return nil
            }
        default:
            if let text = json["text"]?.stringValue {
                self = .text(text)
            } else {
                return nil
            }
        }
    }
}

struct ToolCallView: Sendable, Equatable {
    var toolCallId: String
    var title: String
    var kind: String
    var status: String
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    var contentText: String
    var contents: [ToolCallContentItem]
    var locations: [ToolCallLocation]

    var diffs: [(path: String, oldText: String?, newText: String?)] {
        contents.compactMap { item in
            if case .diff(let path, let oldText, let newText) = item {
                return (path, oldText, newText)
            }
            return nil
        }
    }

    var terminalIds: [String] {
        contents.compactMap { item in
            if case .terminal(let id) = item { return id }
            return nil
        }
    }

    /// How the tool card should render. Harness adapters fill spec fields;
    /// this only looks at those fields plus a few canonical rawInput keys.
    enum CardLayout: String, Sendable, Equatable {
        case command
        case edit
        case file
        case search
        case fetch
        case other
    }

    var cardLayout: CardLayout {
        if !diffs.isEmpty { return .edit }
        if isTerminal || !terminalIds.isEmpty { return .command }
        let k = kind.lowercased()
        if k == "fetch" || fetchURL != nil { return .fetch }
        if k == "search" || Self.extractNonEmptyString(from: rawInput, keys: ["pattern"]) != nil {
            return .search
        }
        if k == "edit" || k == "delete" || k == "move" { return .edit }
        if k == "read" || !locations.isEmpty || filePath != nil { return .file }
        return .other
    }

    var filePath: String? {
        if let path = locations.first?.path, !path.isEmpty { return path }
        return Self.extractNonEmptyString(from: rawInput, keys: ["path"])
    }

    var searchPattern: String? {
        Self.extractNonEmptyString(from: rawInput, keys: ["pattern", "query"])
    }

    var fetchURL: String? {
        Self.extractNonEmptyString(from: rawInput, keys: ["url"])
    }

    init(json: JSONValue) {
        toolCallId = json["toolCallId"]?.stringValue ?? UUID().uuidString
        title = json["title"]?.stringValue ?? json["kind"]?.stringValue ?? "Tool"
        kind = json["kind"]?.stringValue ?? "other"
        status = json["status"]?.stringValue ?? "pending"
        rawInput = json["rawInput"]
        rawOutput = json["rawOutput"]
        if let content = json["content"]?.arrayValue {
            contents = content.compactMap(ToolCallContentItem.init)
            contentText = contents.compactMap { item -> String? in
                if case .text(let text) = item { return text }
                return nil
            }.joined(separator: "\n")
        } else {
            contents = []
            contentText = json["content"]?.stringValue ?? ""
        }
        locations = json["locations"]?.arrayValue?.compactMap(ToolCallLocation.init) ?? []
    }

    @discardableResult
    mutating func merge(_ other: ToolCallView) -> Bool {
        let before = self
        if !other.title.isEmpty, title != other.title, Self.shouldReplaceTitle(existing: title, incoming: other.title) {
            title = other.title
        }
        if !other.kind.isEmpty, kind != other.kind, Self.shouldReplaceKind(existing: kind, incoming: other.kind) {
            kind = other.kind
        }
        if !other.status.isEmpty, status != other.status { status = other.status }
        if let value = other.rawInput, rawInput != value { rawInput = value }
        if let value = other.rawOutput, rawOutput != value { rawOutput = value }
        if !other.contentText.isEmpty, contentText != other.contentText { contentText = other.contentText }
        if !other.contents.isEmpty, contents != other.contents { contents = other.contents }
        if !other.locations.isEmpty, locations != other.locations { locations = other.locations }
        return self != before
    }

    /// `tool_call_update` often omits `title`/`kind`. The parser fills those with
    /// `Tool` / `other`, and a naive merge would wipe a name already inferred
    /// from the first `tool_call`. History replay sends one complete snapshot,
    /// which is why reopening a session looks right.
    private static func shouldReplaceTitle(existing: String, incoming: String) -> Bool {
        isGenericTitleValue(existing) || !isGenericTitleValue(incoming)
    }

    private static func shouldReplaceKind(existing: String, incoming: String) -> Bool {
        let existingSpecific = !existing.isEmpty && existing.lowercased() != "other"
        if incoming.lowercased() == "other", existingSpecific { return false }
        return true
    }

    private static func isGenericTitleValue(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return genericTitles.contains(trimmed.lowercased())
    }

    private static func extractValue(from json: JSONValue?, keys: [String]) -> JSONValue? {
        guard let json else { return nil }
        for key in keys {
            if let val = json[key] {
                return val
            }
        }
        return nil
    }

    private static func nonEmptyString(from val: JSONValue) -> String? {
        if let str = val.stringValue {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : str
        }
        if let arr = val.arrayValue {
            let joined = arr.compactMap(\.stringValue).joined(separator: " ")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractNonEmptyString(from json: JSONValue?, keys: [String]) -> String? {
        guard let json else { return nil }
        for key in keys {
            if let val = json[key], let str = nonEmptyString(from: val) {
                return str
            }
        }
        return nil
    }

    static func titleHasToken(_ title: String, _ candidates: Set<String>) -> Bool {
        let lower = title.lowercased()
        if candidates.contains(lower) { return true }
        let tokens = lower.split { $0 == "_" || $0 == "-" || $0 == "." || $0.isWhitespace }.map(String.init)
        return tokens.contains(where: { candidates.contains($0) })
    }

    var isTerminal: Bool {
        let k = kind.lowercased()
        if k == "execute" || k == "terminal" || k == "shell" || k == "bash" || k == "sh" || k == "command" || k == "run" || k == "exec" {
            return true
        }
        // Custom / un-normalized agents: a command plus a cwd is a shell call.
        // A lone `script` key is not — that matches notebook generators.
        if let input = rawInput,
           Self.extractNonEmptyString(from: input, keys: ["command", "cmd"]) != nil,
           Self.extractNonEmptyString(from: input, keys: ["cwd", "working_dir", "workingDir", "workingDirectory"]) != nil {
            return true
        }
        return !terminalIds.isEmpty
    }

    var terminalCommand: String? {
        guard let input = rawInput else { return nil }
        let commandKeys = ["command", "cmd", "command_line", "commandLine", "CommandLine"]
        guard let val = Self.extractValue(from: input, keys: commandKeys) else { return nil }
        if let str = val.stringValue {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        } else if let arr = val.arrayValue {
            let parts = arr.compactMap(\.stringValue).map { part in
                part.contains(" ") ? "\"\(part)\"" : part
            }
            let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    var terminalCwd: String? {
        guard let input = rawInput else { return nil }
        let cwdKeys = ["cwd", "working_dir", "workingDir", "workingDirectory", "Cwd", "workdir"]
        if let val = Self.extractValue(from: input, keys: cwdKeys), let str = val.stringValue {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    var terminalOutput: String? {
        // content / rawOutput 常被 harness 塞成整段 shell 结果 JSON
        // ({kind, stdout, stderr, …})——先抽 stdout/stderr，别整坨贴出来。
        if let text = Self.shellPlainOutput(from: contentText) { return text }
        if !contentText.isEmpty { return contentText }

        guard let output = rawOutput else { return nil }
        if let text = Self.shellPlainOutput(from: output) { return text }
        if let str = output.stringValue, !str.isEmpty {
            return Self.shellPlainOutput(from: str) ?? str
        }
        return nil
    }

    var terminalExitCode: Int? {
        if let code = Self.shellExitCode(from: rawOutput) { return code }
        if let code = Self.shellExitCode(from: contentText) { return code }
        return nil
    }

    /// Pull human-readable terminal text out of a shell-result envelope.
    private static func shellPlainOutput(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = try? JSONValue.decode(from: trimmed) else {
            return nil
        }
        return shellPlainOutput(from: json)
    }

    private static func shellPlainOutput(from json: JSONValue?) -> String? {
        guard let obj = json?.objectValue else { return nil }
        for key in ["output", "formatted_output", "combinedOutput", "combined_output"] {
            if let val = obj[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
        }
        var pieces: [String] = []
        for key in ["stdout", "stderr"] {
            if let val = obj[key]?.stringValue, !val.isEmpty {
                pieces.append(val)
            }
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: "\n")
    }

    private static func shellExitCode(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = try? JSONValue.decode(from: trimmed) else {
            return nil
        }
        return shellExitCode(from: json)
    }

    private static func shellExitCode(from json: JSONValue?) -> Int? {
        guard let json else { return nil }
        if let code = json["exitCode"]?.int64Value
            ?? json["exit_code"]?.int64Value
            ?? json["returncode"]?.int64Value
            ?? json["code"]?.int64Value {
            return Int(code)
        }
        // Grok often only sends kind: completed / failed
        if let kind = json["kind"]?.stringValue?.lowercased() {
            if kind == "completed" || kind == "success" { return 0 }
            if kind == "failed" || kind == "error" { return 1 }
        }
        return nil
    }

    var otherRawInput: JSONValue? {
        guard let input = rawInput, case .object(let dict) = input else {
            return rawInput
        }
        let knownKeys: Set<String> = [
            "command", "cmd", "command_line", "commandLine", "CommandLine",
            "cmd_line", "cmdLine", "script", "args", "arguments",
            "working_dir", "workingDir", "workingDirectory", "cwd", "Cwd", "dir", "directory", "workdir",
            "path", "file_path", "filePath", "filepath", "target_file", "target_directory", "source_file",
            "ToolName", "ServerName", "toolName", "serverName", "variant",
            "offset", "limit", "line",
            "old_string", "new_string", "oldString", "newString", "content",
            "pattern", "Pattern", "query", "Query", "url", "Url",
            // Consumed by compact title / command body — don't dump as leftover JSON.
            "description", "Description", "intent", "summary",
            "is_background", "isBackground", "background",
            "timeout", "timeout_ms", "timeoutMs", "Timeout",
            "dry_run", "dryRun", "explain", "recursive", "include", "exclude",
            "head_limit", "headLimit", "max_results", "maxResults",
            "case_sensitive", "caseSensitive", "multiline",
        ]
        let remaining = dict.filter { !knownKeys.contains($0.key) }
        guard !remaining.isEmpty else { return nil }
        return .object(remaining)
    }

    var kindLabel: String {
        if isTerminal { return "执行命令".localized }
        let k = kind.lowercased()
        switch k {
        case "read": return "读取文件".localized
        case "edit": return "编辑文件".localized
        case "delete": return "删除文件".localized
        case "move": return "移动文件".localized
        case "execute", "terminal": return "执行命令".localized
        case "search": return "搜索".localized
        case "fetch": return "抓取网页".localized
        default:
            if Self.titleHasToken(title, ["read", "view", "readfile", "viewfile"]) { return "读取文件".localized }
            if Self.titleHasToken(title, ["edit", "write", "create", "editfile", "writefile"]) { return "编辑文件".localized }
            if Self.titleHasToken(title, ["search", "grep", "find"]) { return "搜索".localized }
            return "工具".localized
        }
    }

    private static let genericTitles: Set<String> = [
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

    /// 展示标题：harness 标题有效就直接用；缺失或太泛（不少 harness 只发
    /// "Tool" 或 kind 本身）时，按输入参数推导「动作 · 内容简介」。
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let isGeneric = trimmed.isEmpty ||
            Self.genericTitles.contains(trimmed.lowercased()) ||
            trimmed.lowercased() == kind.lowercased()

        if !isGeneric {
            return trimmed
        }
        guard let brief = derivedBrief else { return kindLabel }
        return "\(kindLabel) · \(brief)"
    }

    /// Model-written intent from `rawInput.description` (Bash etc.).
    /// Used for shell compact titles so the long command stays in the expand body.
    var intentDescription: String? {
        guard let raw = Self.extractNonEmptyString(
            from: rawInput,
            keys: ["description", "Description", "intent", "summary"]
        ) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Collapsed tool-row title. Commands use the model intent (or the command);
    /// the terminal icon already carries "ran", and prefixing 已运行 is wrong
    /// while the tool is still in progress.
    var compactTitle: String {
        switch cardLayout {
        case .command:
            if let intent = intentDescription {
                return intent
            }
            if let cmd = terminalCommand {
                let first = cmd.split(whereSeparator: \.isNewline).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? cmd
                return Self.truncate(first, limit: 72)
            }
            return "命令".localized
        case .file:
            if let name = shortPathLabel {
                return "已读取 %@".localized(name)
            }
            return "已读取文件".localized
        case .edit:
            if let name = shortPathLabel {
                return "已编辑 %@".localized(name)
            }
            return "已编辑文件".localized
        case .search:
            if let pattern = searchPattern {
                return "已搜索 %@".localized(Self.truncate(pattern, limit: 48))
            }
            return "已搜索".localized
        case .fetch:
            if let url = fetchURL {
                return "已抓取 %@".localized(Self.truncate(url, limit: 48))
            }
            return "已抓取".localized
        case .other:
            if let intent = intentDescription {
                return intent
            }
            return displayTitle
        }
    }

    private var shortPathLabel: String? {
        if let path = filePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let loc = locations.first?.path, !loc.isEmpty {
            return URL(fileURLWithPath: loc).lastPathComponent
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }

    private var derivedBrief: String? {
        if isTerminal, let cmd = terminalCommand {
            let firstLine = cmd.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !firstLine.isEmpty {
                return firstLine
            }
        }
        guard let input = rawInput else { return nil }
        let orderedKeys = [
            "command", "path", "pattern", "query", "url",
            "file_path", "filePath", "target_file", "target_directory",
        ]
        guard let raw = Self.extractNonEmptyString(from: input, keys: orderedKeys) else {
            return nil
        }
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return nil }
        if firstLine.hasPrefix("/") || firstLine.hasPrefix("~"), !firstLine.contains(" ") {
            return URL(fileURLWithPath: firstLine).lastPathComponent
        }
        return firstLine
    }
}

struct PlanEntry: Sendable, Equatable {
    var content: String
    var status: String
    var priority: String?

    init?(json: JSONValue) {
        guard let content = json["content"]?.stringValue else { return nil }
        self.content = content
        self.status = json["status"]?.stringValue ?? "pending"
        self.priority = json["priority"]?.stringValue
    }
}

struct SlashCommand: Sendable, Equatable, Identifiable {
    var name: String
    var description: String?

    var id: String { name }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.name = name
        self.description = json["description"]?.stringValue
    }
}

struct PermissionOption: Sendable, Equatable, Identifiable {
    var optionId: String
    var name: String
    var kind: String
    var description: String?

    var id: String { optionId }

    init?(json: JSONValue) {
        guard let optionId = json["optionId"]?.stringValue ?? json["option_id"]?.stringValue else { return nil }
        self.optionId = optionId
        self.name = json["name"]?.stringValue ?? optionId
        self.kind = json["kind"]?.stringValue ?? "allow_once"
        let description = json["description"]?.stringValue
        self.description = description?.isEmpty == false ? description : nil
    }

    var isAllow: Bool { kind.contains("allow") }
}

struct PermissionPrompt: Sendable, Equatable {
    var sessionId: String
    var title: String
    var options: [PermissionOption]
    var toolCall: ToolCallView?

    init?(json: JSONValue) {
        guard let sessionId = json["sessionId"]?.stringValue else { return nil }
        self.sessionId = sessionId
        self.toolCall = json["toolCall"].map(ToolCallView.init)
        self.title = toolCall?.displayTitle ?? "Permission required"
        self.options = json["options"]?.arrayValue?.compactMap(PermissionOption.init) ?? []
    }
}

enum PermissionDecision: Sendable {
    case selected(String)
    case cancelled

    var json: JSONValue {
        switch self {
        case .selected(let optionId):
            return .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionId),
                ])
            ])
        case .cancelled:
            return .object([
                "outcome": .object([
                    "outcome": .string("cancelled"),
                ])
            ])
        }
    }
}
