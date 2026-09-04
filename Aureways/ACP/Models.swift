import Foundation

enum AppInfo {
    static let version = "0.1.1"
}

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

struct EmptyObject: Codable, Sendable, Equatable {}

struct ClientConfigOptionCapabilities: Codable, Sendable {
    var boolean = EmptyObject()
}

struct ClientSessionCapabilities: Codable, Sendable {
    var configOptions = ClientConfigOptionCapabilities()
}

struct ClientCapabilities: Codable, Sendable {
    var fs = FileSystemCapabilities()
    var terminal = true
    var session = ClientSessionCapabilities()
}

struct InitializeRequest: Encodable, Sendable {
    var protocolVersion = 1
    var clientCapabilities = ClientCapabilities()
    var clientInfo = ImplementationInfo(name: "aureways", title: "Aureways", version: AppInfo.version)
}

struct SessionCapabilities: Decodable, Sendable, Equatable {
    var list = false
    var delete = false

    init(list: Bool = false, delete: Bool = false) {
        self.list = list
        self.delete = delete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        list = Self.isEnabled(container, "list")
        delete = Self.isEnabled(container, "delete")
    }

    private static func isEnabled(_ container: KeyedDecodingContainer<DynamicCodingKey>, _ key: String) -> Bool {
        let codingKey = DynamicCodingKey(key)
        if (try? container.decodeNil(forKey: codingKey)) == true { return false }
        if let flag = try? container.decode(Bool.self, forKey: codingKey) { return flag }
        if (try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: codingKey)) != nil { return true }
        return false
    }
}

struct AgentCapabilities: Decodable, Sendable, Equatable {
    var loadSession = false
    var promptCapabilities: PromptCapabilities?
    var sessionCapabilities = SessionCapabilities()

    var canLoad: Bool { loadSession }
    var canList: Bool { sessionCapabilities.list }
    var canDelete: Bool { sessionCapabilities.delete }
    var canPersistHistory: Bool { canLoad || canList }

    init(
        loadSession: Bool = false,
        promptCapabilities: PromptCapabilities? = nil,
        sessionCapabilities: SessionCapabilities = SessionCapabilities()
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.sessionCapabilities = sessionCapabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        loadSession = try container.decodeIfPresent(Bool.self, forKey: DynamicCodingKey("loadSession")) ?? false
        promptCapabilities = try container.decodeIfPresent(PromptCapabilities.self, forKey: DynamicCodingKey("promptCapabilities"))
        sessionCapabilities = try container.decodeIfPresent(SessionCapabilities.self, forKey: DynamicCodingKey("sessionCapabilities")) ?? SessionCapabilities()
    }
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
