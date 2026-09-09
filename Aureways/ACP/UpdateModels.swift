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
        guard case .text(let left) = self, case .text(let right) = other else { return nil }
        return .text(left + right)
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
        guard sessionId == next.sessionId else { return nil }
        switch (update, next.update) {
        case (.agentMessageChunk(let left), .agentMessageChunk(let right)):
            guard let combined = left.concatenating(right) else { return nil }
            return SessionNotification(sessionId: sessionId, update: .agentMessageChunk(combined), messageId: next.messageId ?? messageId)
        case (.agentThoughtChunk(let left), .agentThoughtChunk(let right)):
            guard let combined = left.concatenating(right) else { return nil }
            return SessionNotification(sessionId: sessionId, update: .agentThoughtChunk(combined), messageId: next.messageId ?? messageId)
        case (.userMessageChunk(let left), .userMessageChunk(let right)):
            guard let combined = left.concatenating(right) else { return nil }
            return SessionNotification(sessionId: sessionId, update: .userMessageChunk(combined), messageId: next.messageId ?? messageId)
        case (.toolCallUpdate(let left), .toolCallUpdate(let right)) where left.toolCallId == right.toolCallId:
            var merged = left
            merged.merge(right)
            return SessionNotification(sessionId: sessionId, update: .toolCallUpdate(merged), messageId: next.messageId ?? messageId)
        case (.usage, .usage):
            return next
        case (.availableCommands, .availableCommands):
            return next
        case (.sessionInfo, .sessionInfo):
            return next
        default:
            return nil
        }
    }

    static func coalesced(_ notes: [SessionNotification]) -> [SessionNotification] {
        var result: [SessionNotification] = []
        result.reserveCapacity(notes.count)
        for note in notes {
            if let last = result.last, let merged = last.merging(note) {
                result[result.count - 1] = merged
            } else {
                result.append(note)
            }
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
        if !other.title.isEmpty, title != other.title { title = other.title }
        if !other.kind.isEmpty, kind != other.kind { kind = other.kind }
        if !other.status.isEmpty, status != other.status { status = other.status }
        if let value = other.rawInput, rawInput != value { rawInput = value }
        if let value = other.rawOutput, rawOutput != value { rawOutput = value }
        if !other.contentText.isEmpty, contentText != other.contentText { contentText = other.contentText }
        if !other.contents.isEmpty, contents != other.contents { contents = other.contents }
        if !other.locations.isEmpty, locations != other.locations { locations = other.locations }
        return self != before
    }

    private static func extractValue(from json: JSONValue?, keys: [String]) -> JSONValue? {
        guard let json else { return nil }
        for key in keys {
            if let val = json[key] {
                return val
            }
        }
        for nestedKey in ["Arguments", "arguments", "parameters", "params", "input", "args"] {
            if let nested = json[nestedKey], case .object = nested {
                if let val = extractValue(from: nested, keys: keys) {
                    return val
                }
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
        for nestedKey in ["Arguments", "arguments", "parameters", "params", "input", "args"] {
            if let nested = json[nestedKey], case .object = nested {
                if let str = extractNonEmptyString(from: nested, keys: keys) {
                    return str
                }
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
        let t = title.lowercased()
        if t == "run_command" || t == "runcommand" || t == "execute_command" || t == "executecommand" || t == "bash" || t == "terminal" || t == "sh" || t == "zsh" || t == "exec" {
            return true
        }
        if let toolName = rawInput?["ToolName"]?.stringValue?.lowercased() {
            if toolName == "run_command" || toolName == "execute_command" || toolName == "bash" || toolName == "terminal" {
                return true
            }
        }
        if let input = rawInput {
            let commandKeys = ["command_line", "commandLine", "CommandLine", "cmd_line", "cmdLine"]
            if Self.extractNonEmptyString(from: input, keys: commandKeys) != nil {
                return true
            }
            let generalCommandKeys = ["command", "cmd", "script"]
            let cwdKeys = ["working_dir", "workingDir", "workingDirectory", "cwd", "Cwd"]
            if Self.extractNonEmptyString(from: input, keys: generalCommandKeys) != nil,
               Self.extractNonEmptyString(from: input, keys: cwdKeys) != nil {
                return true
            }
        }
        return false
    }

    var terminalCommand: String? {
        guard let input = rawInput else { return nil }
        let commandKeys = [
            "command_line", "commandLine", "CommandLine",
            "cmd_line", "cmdLine",
            "command", "cmd", "script"
        ]
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
        let cwdKeys = ["working_dir", "workingDir", "workingDirectory", "cwd", "Cwd", "dir", "directory"]
        if let val = Self.extractValue(from: input, keys: cwdKeys), let str = val.stringValue {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    var terminalOutput: String? {
        if !contentText.isEmpty {
            return contentText
        }
        guard let output = rawOutput else { return nil }
        if let str = output.stringValue, !str.isEmpty {
            return str
        }
        if let obj = output.objectValue {
            let outputKeys = ["output", "stdout", "stderr", "result", "text", "response"]
            var pieces: [String] = []
            for key in outputKeys {
                if let val = obj[key]?.stringValue, !val.isEmpty {
                    pieces.append(val)
                }
            }
            if !pieces.isEmpty {
                return pieces.joined(separator: "\n")
            }
        }
        return nil
    }

    var terminalExitCode: Int? {
        guard let out = rawOutput else { return nil }
        if let code = out["exit_code"]?.int64Value ?? out["exitCode"]?.int64Value ?? out["returncode"]?.int64Value ?? out["status"]?.int64Value {
            return Int(code)
        }
        return nil
    }

    var otherRawInput: JSONValue? {
        guard isTerminal, let input = rawInput, case .object(let dict) = input else {
            return rawInput
        }
        let knownTerminalKeys: Set<String> = [
            "command", "cmd", "command_line", "commandLine", "CommandLine",
            "cmd_line", "cmdLine", "script", "args", "arguments",
            "working_dir", "workingDir", "workingDirectory", "cwd", "Cwd", "dir", "directory",
            "ToolName", "ServerName"
        ]
        let remaining = dict.filter { !knownTerminalKeys.contains($0.key) }
        guard !remaining.isEmpty else { return nil }
        return .object(remaining)
    }

    var kindLabel: String {
        if isTerminal { return "执行命令" }
        let k = kind.lowercased()
        switch k {
        case "read": return "读取文件"
        case "edit": return "编辑文件"
        case "delete": return "删除文件"
        case "move": return "移动文件"
        case "execute", "terminal": return "执行命令"
        case "search": return "搜索"
        case "fetch": return "抓取网页"
        default:
            if Self.titleHasToken(title, ["read", "view", "readfile", "viewfile"]) { return "读取文件" }
            if Self.titleHasToken(title, ["edit", "write", "create", "editfile", "writefile"]) { return "编辑文件" }
            if Self.titleHasToken(title, ["search", "grep", "find"]) { return "搜索" }
            return "工具"
        }
    }

    private static let genericTitles: Set<String> = [
        "tool", "tools",
        "execute", "exec", "terminal", "bash", "sh", "zsh", "shell", "run", "command",
        "run_command", "runcommand", "execute_command", "executecommand",
        "read", "read_file", "readfile", "view_file", "viewfile", "client_view_file",
        "edit", "edit_file", "editfile", "write_file", "writefile", "client_edit_file", "client_create_file",
        "delete", "delete_file", "deletefile",
        "search", "grep_search", "find_by_name", "glob_search",
        "fetch", "web_search", "read_url_content", "call_mcp_tool"
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
            "command_line", "commandLine", "CommandLine", "cmd_line", "cmdLine", "command", "cmd", "script",
            "file_path", "path", "filePath", "target_file", "source_file", "notebook_path",
            "Pattern", "pattern", "query", "Query", "url", "Url", "description", "Prompt", "prompt"
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
