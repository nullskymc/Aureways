import Foundation

struct McpServerConfig: Codable, Identifiable, Equatable, Sendable {
    enum Transport: String, Codable, CaseIterable, Sendable {
        case stdio
        case http
        case sse
    }

    var id: UUID
    var name: String
    var transport: Transport
    var command: String
    var arguments: [String]
    var url: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        transport: Transport = .stdio,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.enabled = enabled
    }

    init?(json: JSONValue) {
        let type = json["type"]?.stringValue?.lowercased()
        let command = json["command"]?.stringValue ?? ""
        let url = json["url"]?.stringValue ?? ""
        let name = json["name"]?.stringValue ?? ""
        guard !name.isEmpty else { return nil }
        let transport: Transport
        if type == "http" || (!url.isEmpty && command.isEmpty && type != "stdio") {
            transport = type == "sse" ? .sse : .http
        } else if type == "sse" {
            transport = .sse
        } else {
            transport = .stdio
        }
        self.init(
            name: name,
            transport: transport,
            command: command,
            arguments: json["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            url: url,
            enabled: true
        )
    }

    var summary: String {
        switch transport {
        case .stdio:
            return ([command] + arguments).filter { !$0.isEmpty }.joined(separator: " ")
        case .http, .sse:
            return url
        }
    }

    func json(capabilities: McpCapabilities?) -> JSONValue? {
        guard enabled, !name.isEmpty else { return nil }
        switch transport {
        case .stdio:
            guard !command.isEmpty else { return nil }
            return .object([
                "name": .string(name),
                "command": .string(command),
                "args": .array(arguments.map(JSONValue.string)),
                "env": .array([]),
            ])
        case .http:
            guard capabilities?.http == true, !url.isEmpty else { return nil }
            return .object([
                "type": .string("http"),
                "name": .string(name),
                "url": .string(url),
                "headers": .array([]),
            ])
        case .sse:
            guard capabilities?.sse == true, !url.isEmpty else { return nil }
            return .object([
                "type": .string("sse"),
                "name": .string(name),
                "url": .string(url),
                "headers": .array([]),
            ])
        }
    }
}

struct SessionUsage: Equatable, Sendable {
    var used: Int
    var size: Int
    var costAmount: Double?
    var costCurrency: String?

    var percent: Double {
        guard size > 0 else { return 0 }
        return min(1, Double(used) / Double(size))
    }

    init?(json: JSONValue) {
        let used = json["used"]?.int64Value.map(Int.init)
            ?? json["usedTokens"]?.int64Value.map(Int.init)
        let size = json["size"]?.int64Value.map(Int.init)
            ?? json["sizeTokens"]?.int64Value.map(Int.init)
            ?? json["contextWindow"]?.int64Value.map(Int.init)
        guard let used, let size else { return nil }
        self.used = used
        self.size = size
        if case .number(let value) = json["cost"]?["amount"] {
            costAmount = value
        }
        costCurrency = json["cost"]?["currency"]?.stringValue
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

struct SessionMode: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String?

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["value"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        description = json["description"]?.stringValue
    }
}

struct SessionModeState: Sendable, Equatable {
    var currentModeId: String
    var availableModes: [SessionMode]

    init(currentModeId: String, availableModes: [SessionMode]) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }

    init?(json: JSONValue) {
        let current = json["currentModeId"]?.stringValue ?? json["modeId"]?.stringValue ?? ""
        let modes = json["availableModes"]?.arrayValue?.compactMap(SessionMode.init) ?? []
        if current.isEmpty && modes.isEmpty { return nil }
        currentModeId = current
        availableModes = modes
    }
}

struct SessionConfigOption: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var category: String?
    var type: String
    var value: JSONValue?
    var options: [SessionMode]

    var isBoolean: Bool {
        type == "boolean" || (options.isEmpty && value?.boolValue != nil)
    }

    var isMode: Bool {
        let key = (category ?? id).lowercased()
        return key == "mode" || key == "modes"
    }

    var isModel: Bool {
        let key = (category ?? id).lowercased()
        return key == "model" || key == "models" || id.lowercased() == "modelid"
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["configId"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        description = json["description"]?.stringValue
        category = json["category"]?.stringValue
        type = json["type"]?.stringValue ?? (json["value"]?.boolValue != nil ? "boolean" : "select")
        value = json["value"]
        options = json["options"]?.arrayValue?.compactMap(SessionMode.init) ?? []
    }
}

struct NewSessionResponse: Decodable, Sendable {
    var sessionId: String
    var modes: SessionModeState?
    var configOptions: [SessionConfigOption]
    var mcpServers: [McpServerConfig]

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let sessionId = json["sessionId"]?.stringValue, !sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing sessionId"))
        }
        self.sessionId = sessionId
        modes = json["modes"].flatMap { SessionModeState(json: $0) }
        configOptions = json["configOptions"]?.arrayValue?.compactMap(SessionConfigOption.init(json:)) ?? []
        mcpServers = json["mcpServers"]?.arrayValue?.compactMap(McpServerConfig.init(json:)) ?? []
    }
}

struct LoadSessionRequest: Encodable, Sendable {
    var sessionId: String
    var cwd: String
    var mcpServers: [JSONValue] = []
    var additionalDirectories: [String] = []
    var meta: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case mcpServers
        case additionalDirectories
        case meta = "_meta"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
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

struct LoadSessionResponse: Decodable, Sendable {
    var sessionId: String?
    var modes: SessionModeState?
    var configOptions: [SessionConfigOption]
    var mcpServers: [McpServerConfig]

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        sessionId = json["sessionId"]?.stringValue
        modes = json["modes"].flatMap { SessionModeState(json: $0) }
        configOptions = json["configOptions"]?.arrayValue?.compactMap(SessionConfigOption.init(json:)) ?? []
        mcpServers = json["mcpServers"]?.arrayValue?.compactMap(McpServerConfig.init(json:)) ?? []
    }
}

struct ListSessionsRequest: Encodable, Sendable {
    var cwd: String?
    var cursor: String?

    enum CodingKeys: String, CodingKey {
        case cwd
        case cursor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let cwd { try container.encode(cwd, forKey: .cwd) }
        if let cursor { try container.encode(cursor, forKey: .cursor) }
    }
}

struct SessionListItem: Decodable, Sendable, Equatable {
    var sessionId: String
    var cwd: String?
    var title: String?
    var updatedAt: String?
    var createdAt: String?
    var mcpServers: [McpServerConfig]
    var additionalDirectories: [String]

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let sessionId = json["sessionId"]?.stringValue, !sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing sessionId"))
        }
        self.sessionId = sessionId
        cwd = json["cwd"]?.stringValue
        title = json["title"]?.stringValue
        updatedAt = json["updatedAt"]?.stringValue
        createdAt = json["createdAt"]?.stringValue
        mcpServers = json["mcpServers"]?.arrayValue?.compactMap(McpServerConfig.init(json:)) ?? []
        additionalDirectories = json["additionalDirectories"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct ListSessionsResponse: Decodable, Sendable {
    var sessions: [SessionListItem]
    var nextCursor: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        sessions = try container.decodeIfPresent([SessionListItem].self, forKey: DynamicCodingKey("sessions")) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("nextCursor"))
    }
}

struct DeleteSessionRequest: Encodable, Sendable {
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
