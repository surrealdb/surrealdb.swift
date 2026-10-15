import Foundation

/// insert, insertRelation, merge, patch, relate and record-range operations.
/// Like the rest of the CRUD helpers, these compile to SurrealQL with every
/// table, record id and value sent as a bound variable.
extension SurrealClientCore {
    private static let target = "_sdk_target"
    private static let data = "_sdk_data"

    private func run<T: Decodable & Sendable>(
        _ sql: String,
        _ bindings: [String: SurrealValue],
        session: SessionID?,
        txn: UUID?
    ) async throws -> [T] {
        try await query(SurrealQuery<T>(sql: sql, bindings: bindings), session: session, txn: txn)
    }

    func insert<Model: SurrealModel & Codable & Sendable>(
        _ values: [Model],
        relation: Bool,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        let content = SurrealValue.array(try values.map { try SurrealValue.fromEncodable($0) })
        let statement = relation ? "INSERT RELATION INTO" : "INSERT INTO"
        return try await run(
            "\(statement) $\(Self.target) $\(Self.data);",
            [Self.target: .table(Model.surrealTable), Self.data: content],
            session: session,
            txn: txn
        )
    }

    func merge<Model: Decodable & Sendable>(
        target: SurrealValue,
        where predicate: SurrealPredicate?,
        data: SurrealValue,
        as model: Model.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        var bindings: [String: SurrealValue] = [Self.target: target, Self.data: data]
        var sql = "UPDATE $\(Self.target) MERGE $\(Self.data)"
        if let predicate {
            sql += " WHERE \(predicate.raw)"
            bindings.merge(predicate.bindings) { current, _ in current }
        }
        return try await run(sql + ";", bindings, session: session, txn: txn)
    }

    func patch<Model: Decodable & Sendable>(
        recordID: SurrealRecordID,
        operations: [SurrealPatchOperation],
        as model: Model.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> Model? {
        let results: [Model] = try await run(
            "UPDATE $\(Self.target) PATCH $\(Self.data);",
            [Self.target: .recordID(recordID), Self.data: .array(operations.map(\.surrealValue))],
            session: session,
            txn: txn
        )
        return results.first
    }

    func relate<Edge: Decodable & Sendable>(
        from: [SurrealRecordID],
        edge: String,
        to: [SurrealRecordID],
        content: SurrealValue?,
        as type: Edge.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Edge] {
        var bindings: [String: SurrealValue] = [
            "_sdk_from": from.count == 1 ? .recordID(from[0]) : .array(from.map(SurrealValue.recordID)),
            "_sdk_edge": .table(edge),
            "_sdk_to": to.count == 1 ? .recordID(to[0]) : .array(to.map(SurrealValue.recordID)),
        ]
        var sql = "RELATE $_sdk_from->$_sdk_edge->$_sdk_to"
        if let content {
            sql += " CONTENT $\(Self.data)"
            bindings[Self.data] = content
        }
        return try await run(sql + ";", bindings, session: session, txn: txn)
    }

    func select<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        try await run("SELECT * FROM $\(Self.target);", [Self.target: range.surrealValue], session: session, txn: txn)
    }

    func delete<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        try await run("DELETE $\(Self.target) RETURN BEFORE;", [Self.target: range.surrealValue], session: session, txn: txn)
    }
}
