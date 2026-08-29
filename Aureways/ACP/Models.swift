import Foundation

enum ACPError: LocalizedError, Sendable {
    case invalidJSON(String)
    case transportClosed(String)
    case agent(Int, String)
    case launch(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message): return message
        case .transportClosed(let message): return message
        case .agent(let code, let message): return "Agent error \(code): \(message)"
        case .launch(let message): return message
        case .timeout(let message): return message
        }
    }
}

struct ImplementationInfo: Codable, Sendable, Equatable {
    var name: String
    var title: String?
    var version: String
}

struct FileSystemCapabilities: Codable, Sendable {
    var readTextFile = true
    var writeTextFile = true
}

struct ClientCapabilities: Codable, Sendable {
    var fs = FileSystemCapabilities()
    var terminal = true
}

struct InitializeRequest: Encodable, Sendable {
    var protocolVersion = 1
    var clientCapabilities = ClientCapabilities()
    var clientInfo = ImplementationInfo(name: "aureways", title: "Aureways", version: "0.1.0")
}

struct AgentCapabilities: Decodable, Sendable, Equatable {
    var loadSession: Bool?
    var promptCapabilities: PromptCapabilities?
}

struct PromptCapabilities: Decodable, Sendable, Equatable {
    var image: Bool?
    var audio: Bool?
    var embeddedContext: Bool?
}

struct AuthMethod: Decodable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String?
    var description: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try container.decode(String.self, forKey: DynamicCodingKey("id"))
        name = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("name"))
        description = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("description"))
    }
}

struct InitializeResponse: Decodable, Sendable, Equatable {
    var protocolVersion: Int?
    var agentCapabilities: AgentCapabilities?
    var agentInfo: ImplementationInfo?
    var authMethods: [AuthMethod]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: DynamicCodingKey("protocolVersion"))
        agentCapabilities = try container.decodeIfPresent(AgentCapabilities.self, forKey: DynamicCodingKey("agentCapabilities"))
        agentInfo = try container.decodeIfPresent(ImplementationInfo.self, forKey: DynamicCodingKey("agentInfo"))
        authMethods = try container.decodeIfPresent([AuthMethod].self, forKey: DynamicCodingKey("authMethods")) ?? []
    }
}

struct NewSessionRequest: Encodable, Sendable {
    var cwd: String
    var mcpServers: [JSONValue] = []
    var additionalDirectories: [String] = []
    var meta: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case cwd
        case mcpServers
        case additionalDirectories
        case meta = "_meta"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(mcpServers, forKey: .mcpServers)
        if !additionalDirectories.isEmpty {
            try container.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        if let meta {
            try container.encode(meta, forKey: .meta)
        }
    }
}

struct NewSessionResponse: Decodable, Sendable {
    var sessionId: String
}

struct PromptRequest: Encodable, Sendable {
    var sessionId: String
    var prompt: [ContentBlock]
}

struct PromptResponse: Decodable, Sendable {
    var stopReason: String?
}

struct CancelNotification: Encodable, Sendable {
    var sessionId: String
}

enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case other(JSONValue)

    var text: String? {
        if case .text(let value) = self { return value }
        if case .other(let json) = self { return json["text"]?.stringValue }
        return nil
    }

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        if json["type"]?.stringValue == "text", let text = json["text"]?.stringValue {
            self = .text(text)
        } else {
            self = .other(json)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            try JSONValue.object([
                "type": .string("text"),
                "text": .string(text),
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
        default:
            self = .unknown(kind, json)
        }
    }

    private static func decodeContent(_ json: JSONValue?) -> ContentBlock {
        guard let json else { return .text("") }
        if json["type"]?.stringValue == "text" {
            return .text(json["text"]?.stringValue ?? "")
        }
        return .other(json)
    }
}

struct SessionNotification: Sendable, Equatable {
    var sessionId: String
    var update: SessionUpdate

    init?(json: JSONValue) {
        guard let sessionId = json["sessionId"]?.stringValue else { return nil }
        self.sessionId = sessionId
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
        self.title = toolCall?.title ?? "Permission required"
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

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, let int = Int(exactly: value) {
                try container.encode(int)
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
