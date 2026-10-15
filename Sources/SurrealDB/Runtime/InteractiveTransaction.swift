import Foundation

/// A transaction held open on the server, which statements join one call at
/// a time until ``commit()`` or ``cancel()``.
///
/// Unlike `transaction { tx in ... }`, which sends every statement in one
/// `BEGIN ... COMMIT` query, an interactive transaction lets you read
/// results and decide what to do next before committing. Nothing it writes
/// is visible to other sessions until it commits.
///
/// Open one with `beginTransaction()` or `withTransaction { tx in ... }` on a
/// client or session. WebSocket only: the server doesn't allow it over HTTP.
/// The transaction lives on the connection, so it's lost if the connection
/// drops; later calls on it throw.
public struct SurrealInteractiveTransaction: Sendable {
    private let core: SurrealClientCore
    private let session: SessionID?

    /// The transaction's id on the server.
    public let id: UUID

    init(core: SurrealClientCore, session: SessionID?, id: UUID) {
        self.core = core
        self.session = session
        self.id = id
    }

    /// Commits the transaction. Throws if the server can't, for example
    /// because of a conflicting write; the transaction is then gone.
    public func commit() async throws {
        try await core.commitTransaction(id, session: session)
    }

    /// Discards everything the transaction wrote.
    public func cancel() async throws {
        try await core.cancelTransaction(id, session: session)
    }

    public func query<T: Decodable & Sendable>(_ query: SurrealQuery<T>) async throws -> [T] {
        try await core.query(query, session: session, txn: id)
    }

    public func queryRaw(_ sql: String, bindings: [String: SurrealValue] = [:]) async throws -> [RPCQueryResult] {
        try await core.queryRaw(sql, bindings: bindings, session: session, txn: id)
    }

    public func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        limit: Int? = nil,
        start: Int? = nil
    ) async throws -> [Model] {
        try await core.select(model, where: predicate, limit: limit, start: start, session: session, txn: id)
    }

    public func select<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.select(recordID: recordID, as: model, session: session, txn: id)
    }

    public func create<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> [Model] {
        try await core.create(value, session: session, txn: id)
    }

    public func create<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.create(recordID: recordID, content: content, session: session, txn: id)
    }

    /// Replaces the content of every record matching `predicate`.
    public func update<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.update(model, content: content, where: predicate, session: session, txn: id)
    }

    /// Replaces the content of every record in the table with `content`.
    public func updateAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model] {
        try await core.update(model, content: content, where: nil, session: session, txn: id)
    }

    public func update<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.update(recordID: recordID, content: content, session: session, txn: id)
    }

    /// Replaces the content of every record matching `predicate`.
    public func upsert<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.upsert(model, content: content, where: predicate, session: session, txn: id)
    }

    /// Replaces the content of every record in the table with `content`.
    public func upsertAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model] {
        try await core.upsert(model, content: content, where: nil, session: session, txn: id)
    }

    public func upsert<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.upsert(recordID: recordID, content: content, session: session, txn: id)
    }

    /// Inserts `values` into `Model`'s table in one statement and returns
    /// the inserted records.
    public func insert<Model: SurrealModel & Codable & Sendable>(_ values: [Model]) async throws -> [Model] {
        try await core.insert(values, relation: false, session: session, txn: id)
    }

    /// Inserts one record into `Model`'s table.
    public func insert<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> Model? {
        try await core.insert([value], relation: false, session: session, txn: id).first
    }

    /// Inserts edges into `Edge`'s table, which must be a relation table.
    /// Each edge needs `in` and `out` record ids.
    public func insertRelation<Edge: SurrealModel & Codable & Sendable>(_ edges: [Edge]) async throws -> [Edge] {
        try await core.insert(edges, relation: true, session: session, txn: id)
    }

    /// Merges `data` into a record, leaving fields it doesn't mention alone.
    /// `data` is usually a dictionary or a type with just the fields to
    /// change. A `nil` optional property is left out, so that field keeps
    /// its value; to clear a field, pass `SurrealValue.null` for it.
    public func merge<Model: Decodable & Sendable>(
        recordID: SurrealRecordID,
        with data: some Encodable & Sendable,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.merge(target: .recordID(recordID), where: nil, data: SurrealValue.fromEncodable(data), as: model, session: session, txn: id).first
    }

    /// Merges `data` into every record of `Model`'s table matching
    /// `predicate`.
    public func merge<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        with data: some Encodable & Sendable,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.merge(target: .table(Model.surrealTable), where: predicate, data: SurrealValue.fromEncodable(data), as: model, session: session, txn: id)
    }

    /// Merges `data` into every record whose id is in `range`.
    public func merge<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        with data: some Encodable & Sendable,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.merge(target: range.surrealValue, where: nil, data: SurrealValue.fromEncodable(data), as: model, session: session, txn: id)
    }

    /// Applies JSON Patch operations to a record. If any operation fails,
    /// including a `test`, the record is left unchanged and this throws.
    public func patch<Model: Decodable & Sendable>(
        recordID: SurrealRecordID,
        _ operations: [SurrealPatchOperation],
        as model: Model.Type
    ) async throws -> Model? {
        try await core.patch(recordID: recordID, operations: operations, as: model, session: session, txn: id)
    }

    /// Creates an `edge` record from `from` to `to` (`RELATE from->edge->to`)
    /// and returns it.
    public func relate<Edge: Decodable & Sendable>(
        _ from: SurrealRecordID,
        _ edge: String,
        _ to: SurrealRecordID,
        content: SurrealValue? = nil,
        as type: Edge.Type
    ) async throws -> Edge? {
        try await core.relate(from: [from], edge: edge, to: [to], content: content, as: type, session: session, txn: id).first
    }

    /// Creates an `edge` record from every record in `from` to every record
    /// in `to`.
    public func relate<Edge: Decodable & Sendable>(
        _ from: [SurrealRecordID],
        _ edge: String,
        _ to: [SurrealRecordID],
        content: SurrealValue? = nil,
        as type: Edge.Type
    ) async throws -> [Edge] {
        try await core.relate(from: from, edge: edge, to: to, content: content, as: type, session: session, txn: id)
    }

    /// Selects the records whose ids are in `range`.
    public func select<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.select(range: range, as: model, session: session, txn: id)
    }

    /// Deletes the records whose ids are in `range`, returning them as they
    /// were.
    public func delete<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.delete(range: range, as: model, session: session, txn: id)
    }

    public func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil
    ) async throws -> [Model] {
        try await core.delete(model, where: predicate, session: session, txn: id)
    }

    public func delete<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.delete(recordID: recordID, as: model, session: session, txn: id)
    }
}

extension SurrealClientCore {
    func withTransaction<T: Sendable>(
        session: SessionID?,
        _ body: @Sendable (SurrealInteractiveTransaction) async throws -> T
    ) async throws -> T {
        let id = try await beginTransaction(session: session)
        let transaction = SurrealInteractiveTransaction(core: self, session: session, id: id)
        let result: T
        do {
            result = try await body(transaction)
        } catch {
            // If `body` threw because this task was cancelled, a cancel sent
            // from here would be refused before it left the client, leaving
            // the transaction open on the server. Send it from a task of its
            // own.
            await Task.detached { try? await transaction.cancel() }.value
            throw error
        }
        try await transaction.commit()
        return result
    }
}
