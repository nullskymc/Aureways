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
            let id = json["configId"]?.stringValue ?? json["id"]?.stringValue ?? json["configOption"]?["id"]?.stringValue ?? ""
            let value = json["value"] ?? json["configOption"]?["value"] ?? .null
            self = .configOption(id, value)
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

#if false
enum MarkdownBlocksRemoved { // homemade parser retired; SwiftStreamingMarkdown owns rendering
    static func ignore(_ source: String) {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if index + 1 < lines.count, isTableRow(line), isTableSeparator(lines[index + 1]) {
                let headers = splitTableRow(line)
                let alignments = splitTableRow(lines[index + 1]).map(tableAlignment)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, isTableRow(lines[index]), !isTableSeparator(lines[index]) {
                    rows.append(splitTableRow(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                continue
            }
            if let fence = fenceHeader(line) {
                var body: [String] = []
                index += 1
                while index < lines.count, !fenceClose(lines[index], marker: fence.marker) {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(fence.language, body.joined(separator: "\n")))
                continue
            }
            if let heading = heading(line) {
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }
            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }
            if isQuote(line) {
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        if index + 1 < lines.count, isQuote(lines[index + 1]) {
                            quoted.append("")
                            index += 1
                            continue
                        }
                        break
                    }
                    guard isQuote(current) else { break }
                    quoted.append(stripQuote(current))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if let item = listItem(line) {
                var items = [item.text]
                let ordered = item.ordered
                index += 1
                while index < lines.count, let next = listItem(lines[index]), next.ordered == ordered {
                    items.append(next.text)
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if fenceHeader(next) != nil { break }
                if heading(next) != nil { break }
                if isRule(next.trimmingCharacters(in: .whitespaces)) { break }
                if isQuote(next) { break }
                if listItem(next) != nil { break }
                if index + 1 < lines.count, isTableRow(next), isTableSeparator(lines[index + 1]) { break }
                paragraph.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    private static func fenceHeader(_ line: String) -> (marker: Character, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for character in trimmed {
            if character == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        let rest = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return (first, rest.isEmpty ? nil : rest)
    }

    private static func fenceClose(_ line: String, marker: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == marker else { return false }
        var count = 0
        for character in trimmed {
            if character == marker { count += 1 } else { return false }
        }
        return count >= 3
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return nil }
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        return (level, rest.drop(while: { $0 == " " }).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" })
    }

    private static func isQuote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func stripQuote(_ line: String) -> String {
        var rest = Substring(line)
        while rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
        if rest.first == ">" { rest = rest.dropFirst() }
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        return splitTableRow(trimmed).count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            return !compact.isEmpty && compact.allSatisfy { $0 == "-" }
        }
    }

    static func splitTableRow(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func tableAlignment(_ cell: String) -> TableAlignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let leading = trimmed.hasPrefix(":")
        let trailing = trimmed.hasSuffix(":")
        switch (leading, trailing) {
        case (true, true): return .center
        case (false, true): return .right
        case (true, false): return .left
        default: return .none
        }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (false, String(trimmed.dropFirst(2)))
        }
        var digits = 0
        for character in trimmed {
            if character.isNumber { digits += 1 } else { break }
        }
        guard digits > 0 else { return nil }
        let rest = trimmed.dropFirst(digits)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, String(rest.dropFirst(2)))
    }
}
#endif

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

    mutating func merge(_ other: ToolCallView) {
        if !other.title.isEmpty { title = other.title }
        if !other.kind.isEmpty { kind = other.kind }
        if !other.status.isEmpty { status = other.status }
        if other.rawInput != nil { rawInput = other.rawInput }
        if other.rawOutput != nil { rawOutput = other.rawOutput }
        if !other.contentText.isEmpty { contentText = other.contentText }
        if !other.contents.isEmpty { contents = other.contents }
        if !other.locations.isEmpty { locations = other.locations }
    }

    /// 展示标题：harness 标题有效就直接用；缺失或太泛（不少 harness 只发
    /// "Tool" 或 kind 本身）时，按输入参数推导「动作 · 内容简介」。
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != "Tool", trimmed.lowercased() != kind.lowercased() {
            return trimmed
        }
        guard let brief = derivedBrief else { return kindLabel }
        return "\(kindLabel) · \(brief)"
    }

    var kindLabel: String {
        switch kind {
        case "read": return "读取文件"
        case "edit": return "编辑文件"
        case "delete": return "删除文件"
        case "move": return "移动文件"
        case "execute": return "执行命令"
        case "search": return "搜索"
        case "fetch": return "抓取网页"
        default: return "工具"
        }
    }

    private var derivedBrief: String? {
        guard let input = rawInput else { return nil }
        let orderedKeys: [String]
        switch kind {
        case "execute":
            orderedKeys = ["command", "cmd", "description"]
        default:
            orderedKeys = ["file_path", "path", "filePath", "notebook_path", "pattern", "query", "url", "description"]
        }
        for key in orderedKeys {
            guard let raw = input[key]?.stringValue else { continue }
            let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !firstLine.isEmpty else { continue }
            if firstLine.hasPrefix("/") || firstLine.hasPrefix("~"), !firstLine.contains(" ") {
                return URL(fileURLWithPath: firstLine).lastPathComponent
            }
            return firstLine
        }
        return nil
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

    var id: String { optionId }

    init?(json: JSONValue) {
        guard let optionId = json["optionId"]?.stringValue ?? json["option_id"]?.stringValue else { return nil }
        self.optionId = optionId
        self.name = json["name"]?.stringValue ?? optionId
        self.kind = json["kind"]?.stringValue ?? "allow_once"
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
