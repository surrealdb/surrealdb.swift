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
    ///
    /// Throws `CancellationError` without committing if the task is already
    /// cancelled. Once the commit has started, cancelling the task no longer
    /// stops it: this waits for the server's answer.
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
        do {
            try await transaction.commit()
        } catch {
            // The commit may never have been sent (this task was cancelled
            // after `body` returned), so roll back the same way. A commit
            // that was sent finishes regardless, so this can't undo one.
            await Task.detached { try? await transaction.cancel() }.value
            throw error
        }
        return result
    }
}
