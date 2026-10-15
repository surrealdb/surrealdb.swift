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

    /// Inserts `values` into `Model`'s table in one statement and returns
    /// the inserted records.
    public func insert<Model: SurrealModel & Codable & Sendable>(_ values: [Model]) async throws -> [Model] {
        try await core.insert(values, relation: false, session: id)
    }

    /// Inserts one record into `Model`'s table.
    public func insert<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> Model? {
        try await core.insert([value], relation: false, session: id).first
    }

    /// Inserts edges into `Edge`'s table, which must be a relation table.
    /// Each edge needs `in` and `out` record ids.
    public func insertRelation<Edge: SurrealModel & Codable & Sendable>(_ edges: [Edge]) async throws -> [Edge] {
        try await core.insert(edges, relation: true, session: id)
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
        try await core.merge(target: .recordID(recordID), where: nil, data: SurrealValue.fromEncodable(data), as: model, session: id).first
    }

    /// Merges `data` into every record of `Model`'s table matching
    /// `predicate`.
    public func merge<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        with data: some Encodable & Sendable,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.merge(target: .table(Model.surrealTable), where: predicate, data: SurrealValue.fromEncodable(data), as: model, session: id)
    }

    /// Merges `data` into every record whose id is in `range`.
    public func merge<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        with data: some Encodable & Sendable,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.merge(target: range.surrealValue, where: nil, data: SurrealValue.fromEncodable(data), as: model, session: id)
    }

    /// Applies JSON Patch operations to a record. If any operation fails,
    /// including a `test`, the record is left unchanged and this throws.
    public func patch<Model: Decodable & Sendable>(
        recordID: SurrealRecordID,
        _ operations: [SurrealPatchOperation],
        as model: Model.Type
    ) async throws -> Model? {
        try await core.patch(recordID: recordID, operations: operations, as: model, session: id)
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
        try await core.relate(from: [from], edge: edge, to: [to], content: content, as: type, session: id).first
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
        try await core.relate(from: from, edge: edge, to: to, content: content, as: type, session: id)
    }

    /// Selects the records whose ids are in `range`.
    public func select<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.select(range: range, as: model, session: id)
    }

    /// Deletes the records whose ids are in `range`, returning them as they
    /// were.
    public func delete<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.delete(range: range, as: model, session: id)
    }

    /// Calls a server-side function by name, such as `fn::greet` or
    /// `string::len`, with `arguments`. `version` picks a version of a
    /// `DEFINE MODEL` function.
    public func run(_ name: String, version: String? = nil, arguments: [SurrealValue] = []) async throws -> SurrealValue {
        try await core.run(name, version: version, arguments: arguments, session: id)
    }

    /// Calls a server-side function and decodes its result as `T`.
    public func run<T: Decodable>(
        _ name: String,
        version: String? = nil,
        arguments: [SurrealValue] = [],
        as type: T.Type
    ) async throws -> T {
        try await core.run(name, version: version, arguments: arguments, session: id).decode(type)
    }

    /// Calls a `DEFINE API` endpoint on the selected database. A path with
    /// no matching endpoint returns status 404 rather than throwing.
    public func api(
        _ path: String,
        method: SurrealAPIMethod = .get,
        body: SurrealValue? = nil,
        headers: [String: String] = [:],
        query: [String: String] = [:]
    ) async throws -> SurrealAPIResponse {
        try await core.api(path, method: method, body: body, headers: headers, query: query, session: id)
    }

    /// Runs a SurrealQL dump, such as one from `export()`, against the
    /// selected database over HTTP (`POST /import`). The dump must start
    /// with `OPTION IMPORT;`, as exports do. The import isn't transactional:
    /// if some statements fail, the rest still apply and this throws
    /// `SurrealError.importFailed` listing the failures.
    public func `import`(_ sql: String) async throws {
        try await core.importSQL(sql, session: id)
    }

    /// Exports the selected database as SurrealQL over HTTP (`/export`).
    /// With no options, everything is exported.
    public func export(_ options: SurrealExportOptions? = nil) async throws -> String {
        try await core.export(options, session: id)
    }

    /// Opens an interactive transaction: statements sent through the returned
    /// handle run inside it until you call `commit()` or `cancel()`.
    /// WebSocket only; throws `SurrealError.unsupportedFeature` over HTTP.
    public func beginTransaction() async throws -> SurrealInteractiveTransaction {
        let txn = try await core.beginTransaction(session: id)
        return SurrealInteractiveTransaction(core: core, session: id, id: txn)
    }

    /// Runs `body` in an interactive transaction, committing it if `body`
    /// returns and cancelling it if `body` throws.
    public func withTransaction<T: Sendable>(
        _ body: @Sendable (SurrealInteractiveTransaction) async throws -> T
    ) async throws -> T {
        try await core.withTransaction(session: id, body)
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
