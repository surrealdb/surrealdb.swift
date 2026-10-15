import Foundation

extension SurrealRange {
    /// `begin..=end`
    public init(_ range: ClosedRange<Int64>) {
        self.init(begin: .included(.int(range.lowerBound)), end: .included(.int(range.upperBound)))
    }

    /// `begin..end`
    public init(_ range: Range<Int64>) {
        self.init(begin: .included(.int(range.lowerBound)), end: .excluded(.int(range.upperBound)))
    }

    /// `begin..`
    public init(_ range: PartialRangeFrom<Int64>) {
        self.init(begin: .included(.int(range.lowerBound)), end: .unbounded)
    }

    /// `..end`
    public init(_ range: PartialRangeUpTo<Int64>) {
        self.init(begin: .unbounded, end: .excluded(.int(range.upperBound)))
    }

    /// `..=end`
    public init(_ range: PartialRangeThrough<Int64>) {
        self.init(begin: .unbounded, end: .included(.int(range.upperBound)))
    }
}

/// The records of one table whose ids fall in a range, such as
/// `person:1..10` or `log:[2024]..[2025]`.
public struct SurrealRecordRange: Sendable, Hashable, Codable {
    public let table: String
    public let range: SurrealRange

    public init(table: String, range: SurrealRange) {
        self.table = table
        self.range = range
    }

    public init(table: String, begin: SurrealRangeBound, end: SurrealRangeBound) {
        self.init(table: table, range: SurrealRange(begin: begin, end: end))
    }

    /// The range as a record id with a range key, which is how SurrealDB
    /// represents it on the wire.
    public var surrealValue: SurrealValue {
        .recordID(SurrealRecordID(table: table, id: .range(range)))
    }
}

/// One JSON Patch (RFC 6902) operation, for `patch(recordID:_:as:)` and in
/// the changes a `LIVE SELECT DIFF` sends. Paths are JSON Pointers into the
/// record, such as `/name` or `/tags/0`.
public enum SurrealPatchOperation: Sendable, Hashable, Decodable {
    case add(path: String, value: SurrealValue)
    case remove(path: String)
    case replace(path: String, value: SurrealValue)
    case move(from: String, path: String)
    case copy(from: String, path: String)
    case test(path: String, value: SurrealValue)
    /// SurrealDB's extension for strings: `value` is a text diff in
    /// diff-match-patch patch format, applied to the string at `path`.
    case change(path: String, value: String)

    private enum CodingKeys: String, CodingKey {
        case op, path, from, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        let path = try container.decode(String.self, forKey: .path)
        switch op {
        case "add":
            self = .add(path: path, value: try container.decode(SurrealValue.self, forKey: .value))
        case "remove":
            self = .remove(path: path)
        case "replace":
            self = .replace(path: path, value: try container.decode(SurrealValue.self, forKey: .value))
        case "move":
            self = .move(from: try container.decode(String.self, forKey: .from), path: path)
        case "copy":
            self = .copy(from: try container.decode(String.self, forKey: .from), path: path)
        case "test":
            self = .test(path: path, value: try container.decode(SurrealValue.self, forKey: .value))
        case "change":
            self = .change(path: path, value: try container.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: container, debugDescription: "Unknown patch operation \(op).")
        }
    }

    public var surrealValue: SurrealValue {
        switch self {
        case .add(let path, let value):
            return .object(["op": .string("add"), "path": .string(path), "value": value])
        case .remove(let path):
            return .object(["op": .string("remove"), "path": .string(path)])
        case .replace(let path, let value):
            return .object(["op": .string("replace"), "path": .string(path), "value": value])
        case .move(let from, let path):
            return .object(["op": .string("move"), "from": .string(from), "path": .string(path)])
        case .copy(let from, let path):
            return .object(["op": .string("copy"), "from": .string(from), "path": .string(path)])
        case .test(let path, let value):
            return .object(["op": .string("test"), "path": .string(path), "value": value])
        case .change(let path, let value):
            return .object(["op": .string("change"), "path": .string(path), "value": .string(value)])
        }
    }
}
