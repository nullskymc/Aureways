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
    /// Human-readable provider / group label when the agent groups models.
    var group: String?

    init(id: String, name: String, description: String? = nil, group: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.group = group
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["value"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? json["label"]?.stringValue ?? id
        description = json["description"]?.stringValue
        group = json["group"]?.stringValue
        if group?.isEmpty == true { group = nil }
    }

    /// Provider shown in the picker: explicit group, else the `provider/model` id prefix.
    var providerLabel: String? {
        if let group, !group.isEmpty { return group }
        let parts = id.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[0])
    }

    var labeledName: String {
        guard let provider = providerLabel, !name.localizedCaseInsensitiveContains(provider) else {
            return name
        }
        return "\(provider) · \(name)"
    }

    /// Preserve JSON order. Untitled items stay in a leading untitled section.
    static func menuSections(from choices: [SessionMode]) -> [(title: String?, items: [SessionMode])] {
        var order: [String] = []
        var ungrouped: [SessionMode] = []
        var buckets: [String: [SessionMode]] = [:]
        for choice in choices {
            if let provider = choice.providerLabel {
                if buckets[provider] == nil { order.append(provider) }
                buckets[provider, default: []].append(choice)
            } else {
                ungrouped.append(choice)
            }
        }
        var sections: [(String?, [SessionMode])] = []
        if !ungrouped.isEmpty { sections.append((nil, ungrouped)) }
        for title in order {
            sections.append((title, buckets[title] ?? []))
        }
        return sections
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

/// ACP `models` on `session/new` / `session/load`. Grok 1.0.7 advertises
/// reasoning effort on each model's `_meta`, not as `configOptions`.
struct SessionModelInfo: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var meta: JSONValue?

    init?(json: JSONValue) {
        guard let id = json["modelId"]?.stringValue ?? json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? json["label"]?.stringValue ?? id
        description = json["description"]?.stringValue
        meta = json["_meta"]
    }

    var reasoningEffort: String? {
        meta?["reasoningEffort"]?.stringValue
    }

    var reasoningEffortChoices: [SessionMode] {
        meta?["reasoningEfforts"]?.arrayValue?.compactMap(SessionMode.init) ?? []
    }
}

struct SessionModelState: Sendable, Equatable {
    var currentModelId: String
    var availableModels: [SessionModelInfo]

    init(currentModelId: String, availableModels: [SessionModelInfo]) {
        self.currentModelId = currentModelId
        self.availableModels = availableModels
    }

    init?(json: JSONValue) {
        let models = json["availableModels"]?.arrayValue?.compactMap(SessionModelInfo.init) ?? []
        let current = json["currentModelId"]?.stringValue ?? json["modelId"]?.stringValue ?? models.first?.id ?? ""
        if current.isEmpty && models.isEmpty { return nil }
        currentModelId = current
        availableModels = models
    }

    var current: SessionModelInfo? {
        availableModels.first(where: { $0.id == currentModelId }) ?? availableModels.first
    }

    mutating func select(_ modelId: String) {
        guard availableModels.contains(where: { $0.id == modelId }) else { return }
        currentModelId = modelId
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

    /// ACP `thought_level` (Grok: `reasoning_effort`). Category wins over id so a
    /// mis-tagged `category: "mode"` option does not steal the mode chip.
    var isThoughtLevel: Bool {
        let categoryKey = (category ?? "").lowercased()
        if categoryKey == "thought_level" || categoryKey == "thoughtlevel" {
            return true
        }
        if !categoryKey.isEmpty { return false }
        let idKey = id.lowercased()
        return idKey == "thought_level" || idKey == "thoughtlevel"
            || idKey == "reasoning_effort" || idKey == "effort"
    }

    var selectedString: String? {
        Self.scalarValue(value)?.stringValue
    }

    init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        type: String = "select",
        value: JSONValue? = nil,
        options: [SessionMode] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.value = value
        self.options = options
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["configId"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? id
        description = json["description"]?.stringValue
        category = json["category"]?.stringValue
        let current = json["value"] ?? json["currentValue"]
        type = json["type"]?.stringValue ?? (current?.boolValue != nil ? "boolean" : "select")
        value = Self.scalarValue(current) ?? current
        options = Self.parseSelectOptions(json["options"])
    }

    /// Select values are strings. Some agents wrap as `{ "value": "high" }`.
    static func scalarValue(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if value.stringValue != nil || value.boolValue != nil { return value }
        if let inner = value["value"], inner.stringValue != nil || inner.boolValue != nil {
            return inner
        }
        return value
    }

    /// ACP select options are either a flat list or `SessionConfigSelectGroup`
    /// entries (`group` + nested `options`). Multi-provider harnesses use the
    /// grouped shape; flattening without the group label collapses to duplicate names.
    static func parseSelectOptions(_ json: JSONValue?) -> [SessionMode] {
        guard let items = json?.arrayValue else { return [] }
        var result: [SessionMode] = []
        for item in items {
            let nested = item["options"]?.arrayValue
            let looksLikeGroup = nested != nil && (
                item["group"] != nil || (item["value"] == nil && item["id"] == nil)
            )
            if looksLikeGroup, let nested {
                let groupName = nonEmpty(item["name"]?.stringValue) ?? nonEmpty(item["group"]?.stringValue)
                for child in nested {
                    guard var mode = SessionMode(json: child) else { continue }
                    if mode.group == nil { mode.group = groupName }
                    result.append(mode)
                }
            } else if let mode = SessionMode(json: item) {
                result.append(mode)
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func fromModels(_ models: SessionModelState) -> SessionConfigOption {
        SessionConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            value: .string(models.currentModelId),
            options: models.availableModels.map {
                SessionMode(id: $0.id, name: $0.name, description: $0.description)
            }
        )
    }

    static func thoughtLevel(from model: SessionModelInfo, preserving effort: String? = nil) -> SessionConfigOption? {
        let choices = model.reasoningEffortChoices
        guard !choices.isEmpty else { return nil }
        let selected = [effort, model.reasoningEffort].compactMap { $0 }.first { id in
            choices.contains(where: { $0.id == id })
        } ?? choices.first?.id
        return SessionConfigOption(
            id: "reasoning_effort",
            name: "推理强度",
            category: "thought_level",
            value: selected.map(JSONValue.string),
            options: choices
        )
    }
}

struct NewSessionResponse: Decodable, Sendable {
    var sessionId: String
    var modes: SessionModeState?
    var models: SessionModelState?
    var configOptions: [SessionConfigOption]
    var mcpServers: [McpServerConfig]

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let sessionId = json["sessionId"]?.stringValue, !sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing sessionId"))
        }
        self.sessionId = sessionId
        modes = json["modes"].flatMap { SessionModeState(json: $0) }
        models = json["models"].flatMap { SessionModelState(json: $0) }
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
    var models: SessionModelState?
    var configOptions: [SessionConfigOption]
    var mcpServers: [McpServerConfig]

    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        sessionId = json["sessionId"]?.stringValue
        modes = json["modes"].flatMap { SessionModeState(json: $0) }
        models = json["models"].flatMap { SessionModelState(json: $0) }
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
