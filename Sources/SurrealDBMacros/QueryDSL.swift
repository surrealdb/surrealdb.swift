import Foundation

public protocol SurrealModel: Codable, Sendable {
    static var surrealTable: String { get }
}

public struct SurrealField<Model, Value>: Sendable, Hashable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

public struct SurrealBinding<Value: Encodable & Sendable>: Sendable, Hashable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

public func bind<T: Encodable & Sendable>(_ name: String, as: T.Type = T.self) -> SurrealBinding<T> {
    _ = `as`
    return SurrealBinding<T>(name)
}

/// A `WHERE` condition. Values compared against fields are carried in
/// `bindings` and sent as bound variables, never interpolated into `raw`.
public struct SurrealPredicate: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String
    public let bindings: [String: SurrealValue]

    /// A predicate from raw SurrealQL. `raw` is sent as written, so never
    /// build it from untrusted input; reference values as `$name` and pass
    /// them in `bindings` instead.
    public init(raw: String, bindings: [String: SurrealValue] = [:]) {
        self.raw = raw
        self.bindings = bindings
    }

    public init(stringLiteral value: String) {
        self.init(raw: value)
    }

    public var description: String { raw }

    /// This predicate's `raw` text and bindings, merged into `bindings`. A
    /// name this predicate binds to a different value than `bindings` does
    /// is renamed here (in its bindings and `raw`), so both sides keep the
    /// values they were built with.
    public func merged(into bindings: [String: SurrealValue]) -> (raw: String, bindings: [String: SurrealValue]) {
        var merged = bindings
        var text = raw
        for (name, value) in self.bindings.sorted(by: { $0.key < $1.key }) {
            guard let existing = merged[name], existing != value else {
                merged[name] = value
                continue
            }
            let renamed = PredicateBindingNames.next()
            text = SurrealQL.renameParameter(name, to: renamed, in: text)
            merged[renamed] = value
        }
        return (text, merged)
    }
}

/// Combines two predicates' bindings. If both bind the same name to
/// different values, the right-hand one is renamed (in its bindings and its
/// `raw` text), so each side keeps the value it was built with.
private func combine(
    _ lhs: SurrealPredicate,
    _ rhs: SurrealPredicate,
    _ join: (String, String) -> String
) -> SurrealPredicate {
    let (rhsRaw, bindings) = rhs.merged(into: lhs.bindings)
    return .init(raw: join(lhs.raw, rhsRaw), bindings: bindings)
}

public func && (lhs: SurrealPredicate, rhs: @autoclosure () -> SurrealPredicate) -> SurrealPredicate {
    combine(lhs, rhs()) { "(\($0) AND \($1))" }
}

public func || (lhs: SurrealPredicate, rhs: @autoclosure () -> SurrealPredicate) -> SurrealPredicate {
    combine(lhs, rhs()) { "(\($0) OR \($1))" }
}

prefix public func ! (predicate: SurrealPredicate) -> SurrealPredicate {
    .init(raw: "NOT (\(predicate.raw))", bindings: predicate.bindings)
}

/// A Swift value that can be compared against a field in a predicate. It's
/// sent to the server as a bound variable.
public protocol SurrealPredicateValue {
    var surrealPredicateValue: SurrealValue { get }
}

extension String: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .string(self) }
}

extension Int: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .int(Int64(self)) }
}

extension Int64: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .int(self) }
}

extension Double: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .double(self) }
}

extension Bool: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .bool(self) }
}

extension UUID: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .uuid(self) }
}

extension Date: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .datetime(self) }
}

extension SurrealRecordID: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { .recordID(self) }
}

extension SurrealValue: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue { self }
}

extension Optional: SurrealPredicateValue where Wrapped: SurrealPredicateValue {
    public var surrealPredicateValue: SurrealValue {
        switch self {
        case .some(let value): value.surrealPredicateValue
        case .none: .none
        }
    }
}

private func binaryPredicate<Model, Value: SurrealPredicateValue>(
    _ lhs: SurrealField<Model, Value>,
    _ op: String,
    _ rhs: Value
) -> SurrealPredicate {
    let value = rhs.surrealPredicateValue
    switch value {
    case .none, .bytes:
        // JSON can't carry these as bound values (NONE arrives as NULL,
        // bytes as base64 text that no cast decodes), so write them inline.
        return .init(raw: "\(SurrealQL.escapeFieldPath(lhs.name)) \(op) \(value.sqlLiteral)")
    default:
        break
    }
    let name = PredicateBindingNames.next()
    return .init(
        raw: "\(SurrealQL.escapeFieldPath(lhs.name)) \(op) \(SurrealQL.typedParameter(name, for: value))",
        bindings: [name: value]
    )
}

private func binaryPredicate<Model, Value: Encodable & Sendable>(
    _ lhs: SurrealField<Model, Value>,
    _ op: String,
    _ rhs: SurrealBinding<Value>
) -> SurrealPredicate {
    .init(raw: "\(SurrealQL.escapeFieldPath(lhs.name)) \(op) $\(rhs.name)")
}

public func == <Model, Value: SurrealPredicateValue>(lhs: SurrealField<Model, Value>, rhs: Value) -> SurrealPredicate {
    binaryPredicate(lhs, "=", rhs)
}

public func != <Model, Value: SurrealPredicateValue>(lhs: SurrealField<Model, Value>, rhs: Value) -> SurrealPredicate {
    binaryPredicate(lhs, "!=", rhs)
}

public func > <Model, Value: SurrealPredicateValue>(lhs: SurrealField<Model, Value>, rhs: Value) -> SurrealPredicate {
    binaryPredicate(lhs, ">", rhs)
}

public func >= <Model, Value: SurrealPredicateValue>(lhs: SurrealField<Model, Value>, rhs: Value) -> SurrealPredicate {
    binaryPredicate(lhs, ">=", rhs)
}

public func < <Model, Value: SurrealPredicateValue>(lhs: SurrealField<Model, Value>, rhs: Value) -> SurrealPredicate {
    binaryPredicate(lhs, "<", rhs)
}

public func <= <Model, Value: SurrealPredicateValue>(lhs: SurrealField<Model, Value>, rhs: Value) -> SurrealPredicate {
    binaryPredicate(lhs, "<=", rhs)
}

public func == <Model, Value: Encodable & Sendable>(lhs: SurrealField<Model, Value>, rhs: SurrealBinding<Value>) -> SurrealPredicate {
    binaryPredicate(lhs, "=", rhs)
}

public func != <Model, Value: Encodable & Sendable>(lhs: SurrealField<Model, Value>, rhs: SurrealBinding<Value>) -> SurrealPredicate {
    binaryPredicate(lhs, "!=", rhs)
}

public func > <Model, Value: Encodable & Sendable>(lhs: SurrealField<Model, Value>, rhs: SurrealBinding<Value>) -> SurrealPredicate {
    binaryPredicate(lhs, ">", rhs)
}

public func >= <Model, Value: Encodable & Sendable>(lhs: SurrealField<Model, Value>, rhs: SurrealBinding<Value>) -> SurrealPredicate {
    binaryPredicate(lhs, ">=", rhs)
}

public func < <Model, Value: Encodable & Sendable>(lhs: SurrealField<Model, Value>, rhs: SurrealBinding<Value>) -> SurrealPredicate {
    binaryPredicate(lhs, "<", rhs)
}

public func <= <Model, Value: Encodable & Sendable>(lhs: SurrealField<Model, Value>, rhs: SurrealBinding<Value>) -> SurrealPredicate {
    binaryPredicate(lhs, "<=", rhs)
}

public struct SurrealQuery<Result: Decodable & Sendable>: Sendable {
    public let sql: String
    public let bindings: [String: SurrealValue]

    public init(sql: String, bindings: [String: SurrealValue] = [:]) {
        self.sql = sql
        self.bindings = bindings
    }
}

public struct LiveQuery<Result: Decodable & Sendable>: Sendable {
    public let sql: String
    public let bindings: [String: SurrealValue]

    public init(sql: String, bindings: [String: SurrealValue] = [:]) {
        self.sql = sql
        self.bindings = bindings
    }
}

public enum SurrealDSL {
    public static func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        limit: Int? = nil,
        start: Int? = nil,
        bindings: [String: SurrealValue] = [:]
    ) -> SurrealQuery<Model> {
        var sql = "SELECT * FROM \(SurrealQL.escapeIdent(model.surrealTable))"
        let (whereRaw, allBindings) = resolve(bindings, predicate)
        if let whereRaw {
            sql += " WHERE \(whereRaw)"
        }
        if let limit {
            sql += " LIMIT \(limit)"
        }
        if let start {
            sql += " START \(start)"
        }
        return .init(sql: sql + ";", bindings: allBindings)
    }

    public static func create<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        contentBinding: String = "content",
        bindings: [String: SurrealValue] = [:]
    ) -> SurrealQuery<Model> {
        .init(
            sql: "CREATE \(SurrealQL.escapeIdent(model.surrealTable)) CONTENT $\(contentBinding);",
            bindings: bindings
        )
    }

    public static func update<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        contentBinding: String = "content",
        bindings: [String: SurrealValue] = [:]
    ) -> SurrealQuery<Model> {
        var sql = "UPDATE \(SurrealQL.escapeIdent(model.surrealTable)) CONTENT $\(contentBinding)"
        let (whereRaw, allBindings) = resolve(bindings, predicate)
        if let whereRaw {
            sql += " WHERE \(whereRaw)"
        }
        return .init(sql: sql + ";", bindings: allBindings)
    }

    public static func upsert<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        contentBinding: String = "content",
        bindings: [String: SurrealValue] = [:]
    ) -> SurrealQuery<Model> {
        var sql = "UPSERT \(SurrealQL.escapeIdent(model.surrealTable)) CONTENT $\(contentBinding)"
        let (whereRaw, allBindings) = resolve(bindings, predicate)
        if let whereRaw {
            sql += " WHERE \(whereRaw)"
        }
        return .init(sql: sql + ";", bindings: allBindings)
    }

    public static func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        bindings: [String: SurrealValue] = [:]
    ) -> SurrealQuery<Model> {
        var sql = "DELETE \(SurrealQL.escapeIdent(model.surrealTable))"
        let (whereRaw, allBindings) = resolve(bindings, predicate)
        if let whereRaw {
            sql += " WHERE \(whereRaw)"
        }
        return .init(sql: sql + ";", bindings: allBindings)
    }

    public static func live<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        fetch: [String] = [],
        bindings: [String: SurrealValue] = [:]
    ) -> LiveQuery<Model> {
        var sql = "LIVE SELECT * FROM \(SurrealQL.escapeIdent(model.surrealTable))"
        let (whereRaw, allBindings) = resolve(bindings, predicate)
        if let whereRaw {
            sql += " WHERE \(whereRaw)"
        }
        if !fetch.isEmpty {
            sql += " FETCH " + fetch.map(SurrealQL.escapeFieldPath).joined(separator: ", ")
        }
        return .init(sql: sql + ";", bindings: allBindings)
    }

    /// A live query whose notifications carry the change to each record as
    /// patch operations (`LIVE SELECT DIFF`), rather than the whole record.
    /// A created record arrives as a single `replace` of the root path.
    public static func liveDiff<Model: SurrealModel>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        bindings: [String: SurrealValue] = [:]
    ) -> LiveQuery<[SurrealPatchOperation]> {
        var sql = "LIVE SELECT DIFF FROM \(SurrealQL.escapeIdent(model.surrealTable))"
        let (whereRaw, allBindings) = resolve(bindings, predicate)
        if let whereRaw {
            sql += " WHERE \(whereRaw)"
        }
        return .init(sql: sql + ";", bindings: allBindings)
    }

    /// The predicate's text and the bindings for the whole statement. A
    /// predicate binding that clashes with an explicit one is renamed.
    private static func resolve(
        _ bindings: [String: SurrealValue],
        _ predicate: SurrealPredicate?
    ) -> (String?, [String: SurrealValue]) {
        guard let predicate else { return (nil, bindings) }
        return predicate.merged(into: bindings)
    }
}
