import Foundation

enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String, uri: String?)
    case resourceLink(uri: String, name: String)
    case other(JSONValue)

    var text: String? {
        if case .text(let value) = self { return value }
        if case .other(let json) = self { return json["text"]?.stringValue }
        return nil
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
            let blob = resource?["blob"]?.stringValue
            if let blob, !blob.isEmpty {
                self = .image(data: blob, mimeType: mimeType ?? "image/png", uri: uri)
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
        case .resourceLink(let uri, let name):
            try JSONValue.object([
                "type": .string("resource_link"),
                "uri": .string(uri),
                "name": .string(name),
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
}

struct ToolCallView: Sendable, Equatable {
    var toolCallId: String
    var title: String
    var kind: String
    var status: String
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    var contentText: String

    init(json: JSONValue) {
        toolCallId = json["toolCallId"]?.stringValue ?? UUID().uuidString
        title = json["title"]?.stringValue ?? json["kind"]?.stringValue ?? "Tool"
        kind = json["kind"]?.stringValue ?? "other"
        status = json["status"]?.stringValue ?? "pending"
        rawInput = json["rawInput"]
        rawOutput = json["rawOutput"]
        if let content = json["content"]?.arrayValue {
            contentText = content.compactMap { $0["content"]?["text"]?.stringValue ?? $0["text"]?.stringValue }.joined(separator: "\n")
        } else {
            contentText = json["content"]?.stringValue ?? ""
        }
    }

    mutating func merge(_ other: ToolCallView) {
        if !other.title.isEmpty { title = other.title }
        if !other.kind.isEmpty { kind = other.kind }
        if !other.status.isEmpty { status = other.status }
        if other.rawInput != nil { rawInput = other.rawInput }
        if other.rawOutput != nil { rawOutput = other.rawOutput }
        if !other.contentText.isEmpty { contentText = other.contentText }
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
