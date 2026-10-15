import Foundation

public protocol SurrealQueryable: Sendable {
    func use(namespace: String?, database: String?) async throws

    func signin(_ credentials: SignInCredentials) async throws -> AuthTokens
    func signup(_ credentials: SignUpCredentials) async throws -> AuthTokens
    func authenticate(_ token: String) async throws
    func invalidate() async throws

    /// Binds a variable that is merged into every subsequent query's bindings.
    func set(_ name: String, value: SurrealValue) async throws
    /// Removes a previously bound variable.
    func unset(_ name: String) async throws

    func query<T: Decodable & Sendable>(_ query: SurrealQuery<T>) async throws -> [T]
    func queryRaw(_ sql: String, bindings: [String: SurrealValue]) async throws -> [RPCQueryResult]

    func transaction(
        _ build: @Sendable (SurrealTransaction) throws -> Void
    ) async throws -> [RPCQueryResult]

    func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate?,
        limit: Int?,
        start: Int?
    ) async throws -> [Model]

    func create<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> [Model]

    func select<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model?

    func create<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model?

    /// Replaces the content of every record matching `predicate`. To
    /// replace every record in the table, call `updateAll` instead.
    func update<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate
    ) async throws -> [Model]

    /// Replaces the content of every record in the table.
    func updateAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model]

    /// Replaces the content of every record matching `predicate`. To
    /// replace every record in the table, call `upsertAll` instead.
    func upsert<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate
    ) async throws -> [Model]

    /// Replaces the content of every record in the table.
    func upsertAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model]

    func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate?
    ) async throws -> [Model]

    func update<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model?

    func upsert<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model?

    func delete<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model?
}

public protocol SurrealLiveQueryable: SurrealQueryable {
    func live<T: Decodable & Sendable>(_ query: LiveQuery<T>) async throws -> AsyncStream<LiveEvent<T>>
    func kill(liveQueryID: UUID) async throws
}
