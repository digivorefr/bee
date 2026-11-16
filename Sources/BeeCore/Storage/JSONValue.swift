import Foundation

/// A JSON document of unknown shape, for formats (Postman) whose fields change type between
/// versions and exporters.
enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let elements): try container.encode(elements)
        case .object(let members): try container.encode(members)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The value as the text a person would type: strings as is, numbers and booleans spelled out.
    var text: String? {
        switch self {
        case .string(let value):
            value
        case .bool(let value):
            value ? "true" : "false"
        case .number(let value):
            if let integer = Int(exactly: value) { String(integer) } else { String(value) }
        case .null, .array, .object:
            nil
        }
    }
}
