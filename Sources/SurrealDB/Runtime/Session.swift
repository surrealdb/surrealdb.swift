import Foundation

/// A logical session multiplexed over the same physical connection as the
/// `SurrealClient` it was created from. Each session has its own namespace/
/// database selection, authentication state, and bound variables, independent
/// of the client's default session and any other forked sessions.
///
/// Create one via `SurrealClient.newSession()` (blank) or `forkSession()`
/// (clones the current namespace, database, authentication, and variables).
/// Only available on WebSocket endpoints — `SurrealClient.newSession()` and
/// `forkSession()` throw `SurrealError.unsupportedFeature` on HTTP.
///
/// Not to be confused with `SessionContext`, the static namespace/database/
/// token snapshot passed to `SurrealClient.init(session:)` to resume a login —
/// that's local, one-shot configuration with no server-side identity, whereas
/// a `SurrealSession` is live, forkable, closeable, and tracked by the server
/// under its own `SessionID`.
public struct SurrealSession: SurrealLiveQueryable {
    private let core: SurrealClientCore

    /// This session's identifier, as attached on the server.
    public let id: SessionID

    init(core: SurrealClientCore, id: SessionID) {
        self.core = core
        self.id = id
    }

    /// Whether this session is still attached to the connection. Becomes
    /// `false` after `closeSession()`.
    public var isValid: Bool {
        get async { await core.hasSession(id) }
    }

    /// Creates a new session by cloning this session's namespace, database,
    /// authentication, and variables. The clone is independent afterwards —
    /// later changes on either session do not affect the other.
    public func forkSession() async throws -> SurrealSession {
        let newID = try await core.createSession(cloneFrom: id)
        return SurrealSession(core: core, id: newID)
    }

    /// Destroys this session on the server. Using the session afterwards
    /// throws `SurrealError.invalidSession`.
    public func closeSession() async throws {
        try await core.destroySession(id)
    }

    /// Runs `body` with this session and always closes it afterwards, even if
    /// `body` throws.
    public func withSession<T: Sendable>(
        _ body: @Sendable (SurrealSession) async throws -> T
    ) async throws -> T {
        do {
            let result = try await body(self)
            try await closeSession()
            return result
        } catch {
            try? await closeSession()
            throw error
        }
    }

    public func use(namespace: String?, database: String?) async throws {
        try await core.use(namespace: namespace, database: database, session: id)
    }

    public func signin(_ credentials: SignInCredentials) async throws -> AuthTokens {
        try await core.signin(credentials, session: id)
    }

    public func signup(_ credentials: SignUpCredentials) async throws -> AuthTokens {
        try await core.signup(credentials, session: id)
    }

    public func authenticate(_ token: String) async throws {
        try await core.authenticate(token, session: id)
    }

    public func invalidate() async throws {
        try await core.invalidate(session: id)
    }

    /// Authenticates with a token pair, refreshing it first if the access
    /// token has expired. Returns the pair now in use.
    @discardableResult
    public func authenticate(_ tokens: AuthTokens) async throws -> AuthTokens {
        try await core.authenticate(tokens, session: id)
    }

    /// Exchanges the refresh token for a new pair and authenticates with it.
    /// The old refresh token is revoked by the server.
    public func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        try await core.refresh(tokens, session: id)
    }

    /// Revokes a refresh token so it can't be used again.
    public func revoke(_ tokens: AuthTokens) async throws {
        try await core.revoke(tokens, session: id)
    }

    /// The signed-in user's record (`$auth`), or `.none` when not signed in
    /// as a record user.
    public func info() async throws -> SurrealValue {
        try await core.info(session: id)
    }

    /// The signed-in user's record, decoded; `nil` when there isn't one.
    public func info<T: Decodable & Sendable>(as type: T.Type) async throws -> T? {
        let value = try await core.info(session: id)
        if value == .none || value == .null {
            return nil
        }
        return try value.decode(T.self)
    }

    /// Clears this session's namespace, database, authentication and
    /// variables, on the server and locally.
    public func reset() async throws {
        try await core.reset(session: id)
    }

    public func set(_ name: String, value: SurrealValue) async throws {
        try await core.set(name, value: value, session: id)
    }

    public func unset(_ name: String) async throws {
        try await core.unset(name, session: id)
    }

    public func query<T: Decodable & Sendable>(_ query: SurrealQuery<T>) async throws -> [T] {
        try await core.query(query, session: id)
    }

    public func queryRaw(_ sql: String, bindings: [String: SurrealValue] = [:]) async throws -> [RPCQueryResult] {
        try await core.queryRaw(sql, bindings: bindings, session: id)
    }

    public func transaction(
        _ build: @Sendable (SurrealTransaction) throws -> Void
    ) async throws -> [RPCQueryResult] {
        try await core.transaction(build, session: id)
    }

    public func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        limit: Int? = nil,
        start: Int? = nil
    ) async throws -> [Model] {
        try await core.select(model, where: predicate, limit: limit, start: start, session: id)
    }

    public func create<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> [Model] {
        try await core.create(value, session: id)
    }

    public func select<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.select(recordID: recordID, as: model, session: id)
    }

    public func create<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.create(recordID: recordID, content: content, session: id)
    }

    /// Replaces the content of every record matching `predicate`.
    ///
    /// The predicate is required: without one this replaced every record in
    /// the table. Use ``updateAll(_:content:)`` when that's what you want.
    public func update<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.update(model, content: content, where: predicate, session: id)
    }

    /// Replaces the content of every record in the table with `content`.
    public func updateAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model] {
        try await core.update(model, content: content, where: nil, session: id)
    }

    /// Replaces the content of every record matching `predicate`.
    ///
    /// The predicate is required: without one this replaced every record in
    /// the table. Use ``upsertAll(_:content:)`` when that's what you want.
    public func upsert<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.upsert(model, content: content, where: predicate, session: id)
    }

    /// Replaces the content of every record in the table with `content`.
    public func upsertAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model] {
        try await core.upsert(model, content: content, where: nil, session: id)
    }

    public func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil
    ) async throws -> [Model] {
        try await core.delete(model, where: predicate, session: id)
    }

    public func update<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.update(recordID: recordID, content: content, session: id)
    }

    public func upsert<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.upsert(recordID: recordID, content: content, session: id)
    }

    public func delete<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.delete(recordID: recordID, as: model, session: id)
    }

    /// Opens a live query stream scoped to this session. Throws
    /// `SurrealError.unsupportedFeature` when the client was created with an
    /// HTTP endpoint.
    public func live<T: Decodable & Sendable>(_ query: LiveQuery<T>) async throws -> AsyncStream<LiveEvent<T>> {
        try await core.live(query, session: id)
    }

    public func kill(liveQueryID: UUID) async throws {
        try await core.kill(liveQueryID: liveQueryID, session: id)
    }
}
