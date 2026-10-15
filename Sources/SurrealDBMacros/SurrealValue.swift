import Foundation

public struct SurrealRecordID: Sendable, Hashable, Codable {
    public let table: String
    public let id: SurrealValue

    public init(table: String, id: SurrealValue) {
        self.table = table
        self.id = id
    }

    /// The record id as SurrealQL text, escaped the way the server renders
    /// it (`person:alice`, ``person:`123` ``, `person:u'…'`). For display;
    /// the SDK itself sends record ids as bound values.
    public var rawValue: String {
        "\(SurrealQL.displayIdent(table)):\(idText)"
    }

    /// Parses the text form the server sends record ids in over JSON
    /// (`person:alice`, ``person:`123` ``, `person:⟨a b⟩`, `person:42`).
    /// Integer keys become `.int`, everything else `.string`; complex keys
    /// (arrays, objects) are kept as their text. `nil` without a `table:`.
    public init?(parsing text: String) {
        guard let (table, rest) = Self.splitTable(text), !rest.isEmpty else { return nil }
        self.table = table
        if let int = Int64(rest), rest.first != "+" {
            self.id = .int(int)
        } else if let unwrapped = Self.unwrap(rest) {
            self.id = .string(unwrapped)
        } else {
            self.id = .string(rest)
        }
    }

    private static func splitTable(_ text: String) -> (String, String)? {
        if text.first == "`" || text.first == "⟨" {
            let close: Character = text.first == "`" ? "`" : "⟩"
            var escaped = false
            var name = ""
            for (offset, char) in text.dropFirst().enumerated() {
                if escaped {
                    name.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == close {
                    let rest = text.dropFirst(offset + 2)
                    guard rest.first == ":" else { return nil }
                    return (name, String(rest.dropFirst()))
                } else {
                    name.append(char)
                }
            }
            return nil
        }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        return (String(text[..<colon]), String(text[text.index(after: colon)...]))
    }

    /// The contents of a `` `...` `` or `⟨...⟩` key, unescaped.
    private static func unwrap(_ key: String) -> String? {
        guard let open = key.first, let last = key.last, key.count >= 2,
              (open == "`" && last == "`") || (open == "⟨" && last == "⟩")
        else { return nil }
        var result = ""
        var escaped = false
        for char in key.dropFirst().dropLast() {
            if escaped {
                result.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                result.append(char)
            }
        }
        return result
    }

    private var idText: String {
        switch id {
        case .string(let value):
            return SurrealQL.displayIdent(value)
        default:
            return id.sqlLiteral
        }
    }
}

public enum SurrealRangeBound: Sendable, Hashable, Codable {
    case included(SurrealValue)
    case excluded(SurrealValue)
    case unbounded
}

public struct SurrealRange: Sendable, Hashable, Codable {
    public let begin: SurrealRangeBound
    public let end: SurrealRangeBound

    public init(begin: SurrealRangeBound, end: SurrealRangeBound) {
        self.begin = begin
        self.end = end
    }
}

/// A reference to a file in a bucket (`f"bucket:/key"`). The bucket is
/// defined with `DEFINE BUCKET`; files are an experimental server feature.
public struct SurrealFileRef: Sendable, Hashable, Codable {
    public let bucket: String
    public let key: String

    /// `key` is the file's path in the bucket. It always starts with `/`,
    /// which is added when missing, as the server does.
    public init(bucket: String, key: String) {
        self.bucket = bucket
        self.key = key.hasPrefix("/") ? key : "/" + key
    }

    private enum CodingKeys: String, CodingKey {
        case bucket, key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bucket: try container.decode(String.self, forKey: .bucket),
            key: try container.decode(String.self, forKey: .key)
        )
    }

    /// `bucket:/key`, as inside the `f"..."` literal.
    public var rawValue: String {
        "\(bucket):\(key)"
    }
}

public enum SurrealGeometry: Sendable, Hashable, Codable {
    case point([Double])
    case line([[Double]])
    case polygon([[[Double]]])
    case multiPoint([[Double]])
    case multiLine([[[Double]]])
    case multiPolygon([[[[Double]]]])
    case collection([SurrealGeometry])
}

public indirect enum SurrealValue: Sendable, Hashable, Codable {
    case none
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case bytes(Data)

    case datetime(Date)
    case uuid(UUID)
    case decimal(String)
    case duration(String)

    case table(String)
    case recordID(SurrealRecordID)
    case range(SurrealRange)
    case set([SurrealValue])
    case geometry(SurrealGeometry)
    case file(SurrealFileRef)

    case array([SurrealValue])
    case object([String: SurrealValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([SurrealValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: SurrealValue].self) {
            self = .object(value)
            return
        }

        throw DecodingError.typeMismatch(
            SurrealValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported SurrealValue payload.")
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encodeNil()
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .bytes(let value):
            try container.encode(value.base64EncodedString())
        case .datetime(let value):
            try container.encode(SurrealValue.iso8601Fractional(value))
        case .uuid(let value):
            try container.encode(value.uuidString)
        case .decimal(let value):
            try container.encode(value)
        case .duration(let value):
            try container.encode(value)
        case .table(let value):
            try container.encode(value)
        case .recordID(let value):
            try container.encode(value.rawValue)
        case .range(let value):
            try container.encode(String(describing: value))
        case .set(let value):
            try container.encode(value)
        case .geometry(let value):
            try container.encode(String(describing: value))
        case .file(let value):
            try container.encode(value.rawValue)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(Int64(value))
        case let value as Int64:
            self = .int(value)
        case let value as UInt64:
            if value <= UInt64(Int64.max) {
                self = .int(Int64(value))
            } else {
                self = .double(Double(value))
            }
        case let value as Double:
            self = .double(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(SurrealValue.init(jsonObject:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(SurrealValue.init(jsonObject:)))
        default:
            throw SurrealValueError.unsupportedJSONType(String(describing: type(of: jsonObject)))
        }
    }

    public func jsonObject() throws -> Any {
        switch self {
        case .none:
            return NSNull()
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .bytes(let value):
            return value.base64EncodedString()
        case .datetime(let value):
            return SurrealValue.iso8601Fractional(value)
        case .uuid(let value):
            return value.uuidString
        case .decimal(let value):
            return value
        case .duration(let value):
            return value
        case .table(let value):
            return value
        case .recordID(let value):
            return value.rawValue
        case .range(let range):
            return [
                "begin": try range.begin.jsonObject(),
                "end": try range.end.jsonObject(),
            ]
        case .set(let value):
            return try value.map { try $0.jsonObject() }
        case .geometry(let value):
            return ["geometry": String(describing: value)]
        case .file(let value):
            return value.rawValue
        case .array(let value):
            return try value.map { try $0.jsonObject() }
        case .object(let value):
            return try value.mapValues { try $0.jsonObject() }
        }
    }

    /// The value as a SurrealQL literal. Strings are quoted and escaped, and
    /// identifiers are backtick-escaped, so the result is always a single
    /// value. Prefer bound variables over splicing this into a query.
    public var sqlLiteral: String {
        switch self {
        case .none:
            return "NONE"
        case .null:
            return "NULL"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return "\(value)"
        case .double(let value):
            if value.isNaN { return "math::nan" }
            if value.isInfinite { return value > 0 ? "math::inf" : "math::neg_inf" }
            return "\(value)f"
        case .string(let value):
            return SurrealQL.quote(value)
        case .bytes(let value):
            return "encoding::base64::decode(\(SurrealQL.quote(value.base64EncodedString())))"
        case .datetime(let value):
            return "d\(SurrealQL.quote(SurrealValue.iso8601Fractional(value)))"
        case .uuid(let value):
            return "u\(SurrealQL.quote(value.uuidString.lowercased()))"
        case .decimal(let value):
            return SurrealValue.isDecimalText(value) ? "\(value)dec" : "<decimal>\(SurrealQL.quote(value))"
        case .duration(let value):
            return SurrealValue.isDurationText(value) ? value : "<duration>\(SurrealQL.quote(value))"
        case .table(let value):
            return "type::table(\(SurrealQL.quote(value)))"
        case .recordID(let value):
            return value.rawValue
        case .range:
            return "<range>"
        case .set(let value):
            return "[" + value.map(\.sqlLiteral).joined(separator: ", ") + "]"
        case .geometry:
            return "<geometry>"
        case .file(let value):
            // File literals take no escapes, so build it from strings.
            return "type::file(\(SurrealQL.quote(value.bucket)), \(SurrealQL.quote(value.key)))"
        case .array(let value):
            return "[" + value.map(\.sqlLiteral).joined(separator: ", ") + "]"
        case .object(let value):
            let entries = value.map { key, value in
                "\(SurrealQL.quote(key)): \(value.sqlLiteral)"
            }.sorted()
            return "{" + entries.joined(separator: ", ") + "}"
        }
    }

    package static func iso8601Fractional(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `-?digits[.digits][e[+-]digits]`.
    package static func isDecimalText(_ text: String) -> Bool {
        text.range(of: #"^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// One or more `<digits><unit>` parts, e.g. `1h30m`.
    static func isDurationText(_ text: String) -> Bool {
        text.range(of: #"^([0-9]+(ns|us|µs|ms|s|m|h|d|w|y))+$"#, options: .regularExpression) != nil
    }
}

public enum SurrealValueError: Error, Sendable {
    case unsupportedJSONType(String)
}

public extension SurrealRangeBound {
    func jsonObject() throws -> Any {
        switch self {
        case .included(let value):
            return ["included": try value.jsonObject()]
        case .excluded(let value):
            return ["excluded": try value.jsonObject()]
        case .unbounded:
            return ["unbounded": true]
        }
    }
}

public extension JSONEncoder {
    static var surrealDefault: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var surrealDefault: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
