import Foundation

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

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let sessionId = json["sessionId"]?.stringValue, !sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing sessionId"))
        }
        self.sessionId = sessionId
        modes = json["modes"].flatMap { SessionModeState(json: $0) }
        configOptions = json["configOptions"]?.arrayValue?.compactMap(SessionConfigOption.init(json:)) ?? []
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

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        sessionId = json["sessionId"]?.stringValue
        modes = json["modes"].flatMap { SessionModeState(json: $0) }
        configOptions = json["configOptions"]?.arrayValue?.compactMap(SessionConfigOption.init(json:)) ?? []
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
