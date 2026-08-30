import Foundation

enum JSONRPCID: Hashable, Sendable {
    case number(Int64)
    case string(String)

    var json: JSONValue {
        switch self {
        case .number(let value): return .number(Double(value))
        case .string(let value): return .string(value)
        }
    }

    init?(_ value: JSONValue) {
        if let number = value.int64Value {
            self = .number(number)
        } else if let string = value.stringValue {
            self = .string(string)
        } else {
            return nil
        }
    }
}

enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var int64Value: Int64? {
        if case .number(let value) = self { return Int64(value) }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    func encode() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject())
    }

    func jsonObject() throws -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, let int = Int(exactly: value) { return int }
            return value
        case .string(let value): return value
        case .array(let values): return try values.map { try $0.jsonObject() }
        case .object(let values):
            return try values.reduce(into: [String: Any]()) { result, item in
                result[item.key] = try item.value.jsonObject()
            }
        }
    }

    static func decode(from data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONValue(object)
    }

    static func decode(from string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw ACPError.invalidJSON("string is not UTF-8")
        }
        return try decode(from: data)
    }

    init(_ object: Any) throws {
        switch object {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try JSONValue($0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try JSONValue($0) })
        default:
            throw ACPError.invalidJSON("unsupported JSON value \(type(of: object))")
        }
    }
}

enum JSONRPCMessage: Sendable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID?, code: Int, message: String, data: JSONValue?)

    var method: String? {
        switch self {
        case .request(_, let method, _), .notification(let method, _):
            return method
        default:
            return nil
        }
    }

    static func parse(line: String) throws -> JSONRPCMessage {
        let json = try JSONValue.decode(from: line)
        guard let object = json.objectValue else {
            throw ACPError.invalidJSON("message is not an object")
        }
        let method = object["method"]?.stringValue
        let id = object["id"].flatMap(JSONRPCID.init)
        if let method {
            if let id {
                return .request(id: id, method: method, params: object["params"])
            }
            return .notification(method: method, params: object["params"])
        }
        if let id, let result = object["result"] {
            return .response(id: id, result: result)
        }
        if let error = object["error"]?.objectValue {
            let code = error["code"]?.int64Value.map(Int.init) ?? -32603
            let message = error["message"]?.stringValue ?? "Unknown error"
            return .error(id: id, code: code, message: message, data: error["data"])
        }
        throw ACPError.invalidJSON("unrecognized JSON-RPC message")
    }

    func line() throws -> String {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.json
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id.json
            object["result"] = result
        case .error(let id, let code, let message, let data):
            if let id { object["id"] = id.json }
            var error: [String: JSONValue] = [
                "code": .number(Double(code)),
                "message": .string(message),
            ]
            if let data { error["data"] = data }
            object["error"] = .object(error)
        }
        let data = try JSONValue.object(object).encode()
        guard let line = String(data: data, encoding: .utf8) else {
            throw ACPError.invalidJSON("unable to encode UTF-8")
        }
        if line.contains("\n") {
            throw ACPError.invalidJSON("ACP messages must not contain embedded newlines")
        }
        return line
    }
}

func encodeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder.acp.encode(value)
    return try JSONValue.decode(from: data)
}

extension JSONEncoder {
    static let acp: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let acp = JSONDecoder()
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
