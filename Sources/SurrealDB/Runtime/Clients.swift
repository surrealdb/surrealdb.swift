import Foundation

/// A SurrealDB client whose transport is selected from the endpoint scheme.
///
/// `ws://` and `wss://` endpoints use the WebSocket engine, which supports live
/// queries and automatic reconnection. `http://` and `https://` endpoints use
/// the request/response HTTP engine, which does not support live queries; on
/// those endpoints `live(_:)` throws `SurrealError.unsupportedFeature`.
public actor SurrealClient: SurrealLiveQueryable {
    private nonisolated let core: SurrealClientCore

    /// The transport selected for the endpoint.
    public enum Engine: Sendable, Equatable {
        case webSocket
        case http
    }

    /// The engine chosen from the endpoint scheme at initialisation.
    public nonisolated let engine: Engine

    /// This client is always scoped to the connection's default/root session.
    public nonisolated let id: SessionID? = nil

    public init(
        endpoint: String,
        wireProtocol: SurrealWireProtocol = .cbor,
        options: SurrealClientOptions = .init(),
        websocketOptions: SurrealWebSocketOptions = .init(),
        session: SessionContext = .init()
    ) throws {
        let rpcURL = try Endpoint.normalizedRPCURL(from: endpoint)
        let codec = makeWireCodec(wireProtocol)
        let status = ConnectionStatusBroadcaster()

        let transport: any RPCEngine
        switch rpcURL.scheme?.lowercased() {
        case "ws", "wss":
            self.engine = .webSocket
            transport = WebSocketRPCEngine(
                endpoint: rpcURL,
                clientOptions: options,
                wsOptions: websocketOptions,
                codec: codec,
                status: status
            )
        case "http", "https":
            self.engine = .http
            transport = HTTPRPCEngine(
                endpoint: rpcURL,
                options: options,
                codec: codec
            )
        default:
            // Endpoint.normalizedRPCURL already rejects unknown schemes; this
            // keeps the switch exhaustive without a fatalError.
            throw SurrealError.invalidEndpoint(endpoint)
        }

        self.core = SurrealClientCore(
            engine: transport,
            sessionContext: session,
            http: HTTPEndpoints(rpcURL: rpcURL, timeout: options.requestTimeout),
            checkServerVersion: options.checkServerVersion,
            status: status
        )
        self.status = status
    }

    private nonisolated let status: ConnectionStatusBroadcaster

    /// Where the connection stands right now.
    public nonisolated var connectionStatus: SurrealConnectionStatus {
        status.current
    }

    /// A stream that starts with the current status and then yields each
    /// change: `.connecting` and `.connected` on `connect()`,
    /// `.reconnecting(attempt:)` while a WebSocket retries after a drop,
    /// `.connected` once it's back and sessions and live queries are
    /// restored, and `.disconnected` after `close()` or when retrying gives
    /// up. If you fall far behind, older updates are dropped in favour of the
    /// latest.
    public nonisolated func connectionStatusUpdates() -> AsyncStream<SurrealConnectionStatus> {
        status.updates()
    }

    public func connect() async throws {
        try await core.connect()
    }

    public func close() async {
        await core.close()
    }

    /// Creates a new, blank session multiplexed over this same connection —
    /// its namespace, database, authentication, and variables all start
    /// empty. Only available on WebSocket endpoints.
    public func newSession() async throws -> SurrealSession {
        let id = try await core.createSession(cloneFrom: nil)
        return SurrealSession(core: core, id: id)
    }

    /// Lists the session ids currently attached to this connection (not
    /// including the default/root session). Only available on WebSocket
    /// endpoints.
    public func sessions() async throws -> [SessionID] {
        try await core.listSessions()
    }

    /// Re-attaches a handle to a session previously created by this client
    /// (e.g. an id returned from `sessions()`), without validating that it
    /// still exists. Session state is tracked per client instance, so ids
    /// from other clients or connections cannot be adopted here — operations
    /// on such a handle throw `SurrealError.invalidSession`, and its
    /// `isValid` reports `false`.
    public nonisolated func session(id: SessionID) -> SurrealSession {
        SurrealSession(core: core, id: id)
    }

    public func use(namespace: String?, database: String?) async throws {
        try await core.use(namespace: namespace, database: database, session: nil)
    }

    public func signin(_ credentials: SignInCredentials) async throws -> AuthTokens {
        try await core.signin(credentials, session: nil)
    }

    public func signup(_ credentials: SignUpCredentials) async throws -> AuthTokens {
        try await core.signup(credentials, session: nil)
    }

    public func authenticate(_ token: String) async throws {
        try await core.authenticate(token, session: nil)
    }

    public func invalidate() async throws {
        try await core.invalidate(session: nil)
    }

    /// Authenticates with a token pair, refreshing it first if the access
    /// token has expired. Returns the pair now in use.
    @discardableResult
    public func authenticate(_ tokens: AuthTokens) async throws -> AuthTokens {
        try await core.authenticate(tokens, session: nil)
    }

    /// Exchanges the refresh token for a new pair and authenticates with it.
    /// The old refresh token is revoked by the server.
    public func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        try await core.refresh(tokens, session: nil)
    }

    /// Revokes a refresh token so it can't be used again.
    public func revoke(_ tokens: AuthTokens) async throws {
        try await core.revoke(tokens, session: nil)
    }

    /// The signed-in user's record (`$auth`), or `.none` when not signed in
    /// as a record user.
    public func info() async throws -> SurrealValue {
        try await core.info(session: nil)
    }

    /// The signed-in user's record, decoded; `nil` when there isn't one.
    public func info<T: Decodable & Sendable>(as type: T.Type) async throws -> T? {
        let value = try await core.info(session: nil)
        if value == .none || value == .null {
            return nil
        }
        return try value.decode(T.self)
    }

    /// Clears this session's namespace, database, authentication and
    /// variables, on the server and locally.
    public func reset() async throws {
        try await core.reset(session: nil)
    }

    /// The server's version, e.g. `"3.3.4"`.
    public func version() async throws -> String {
        try await core.version()
    }

    /// Checks the server's `/health` endpoint, throwing if it isn't healthy.
    /// Works for WebSocket endpoints too: it goes over HTTP to the same host.
    public func health() async throws {
        try await core.health()
    }

    public func set(_ name: String, value: SurrealValue) async throws {
        try await core.set(name, value: value, session: nil)
    }

    public func unset(_ name: String) async throws {
        try await core.unset(name, session: nil)
    }

    public func query<T: Decodable & Sendable>(_ query: SurrealQuery<T>) async throws -> [T] {
        try await core.query(query, session: nil)
    }

    public func queryRaw(_ sql: String, bindings: [String: SurrealValue] = [:]) async throws -> [RPCQueryResult] {
        try await core.queryRaw(sql, bindings: bindings, session: nil)
    }

    public func transaction(
        _ build: @Sendable (SurrealTransaction) throws -> Void
    ) async throws -> [RPCQueryResult] {
        try await core.transaction(build, session: nil)
    }

    /// Inserts `values` into `Model`'s table in one statement and returns
    /// the inserted records.
    public func insert<Model: SurrealModel & Codable & Sendable>(_ values: [Model]) async throws -> [Model] {
        try await core.insert(values, relation: false, session: nil)
    }

    /// Inserts one record into `Model`'s table.
    public func insert<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> Model? {
        try await core.insert([value], relation: false, session: nil).first
    }

    /// Inserts edges into `Edge`'s table, which must be a relation table.
    /// Each edge needs `in` and `out` record ids.
    public func insertRelation<Edge: SurrealModel & Codable & Sendable>(_ edges: [Edge]) async throws -> [Edge] {
        try await core.insert(edges, relation: true, session: nil)
    }

    /// Merges `data` into a record, leaving fields it doesn't mention alone.
    /// `data` is usually a dictionary or a type with just the fields to
    /// change: a `nil` optional would set that field to `NULL`.
    public func merge<Model: Decodable & Sendable>(
        recordID: SurrealRecordID,
        with data: some Encodable & Sendable,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.merge(target: .recordID(recordID), where: nil, data: SurrealValue.fromEncodable(data), as: model, session: nil).first
    }

    /// Merges `data` into every record of `Model`'s table matching
    /// `predicate`.
    public func merge<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        with data: some Encodable & Sendable,
        where predicate: SurrealPredicate
    ) async throws -> [Model] {
        try await core.merge(target: .table(Model.surrealTable), where: predicate, data: SurrealValue.fromEncodable(data), as: model, session: nil)
    }

    /// Merges `data` into every record whose id is in `range`.
    public func merge<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        with data: some Encodable & Sendable,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.merge(target: range.surrealValue, where: nil, data: SurrealValue.fromEncodable(data), as: model, session: nil)
    }

    /// Applies JSON Patch operations to a record. If any operation fails,
    /// including a `test`, the record is left unchanged and this throws.
    public func patch<Model: Decodable & Sendable>(
        recordID: SurrealRecordID,
        _ operations: [SurrealPatchOperation],
        as model: Model.Type
    ) async throws -> Model? {
        try await core.patch(recordID: recordID, operations: operations, as: model, session: nil)
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
        try await core.relate(from: [from], edge: edge, to: [to], content: content, as: type, session: nil).first
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
        try await core.relate(from: from, edge: edge, to: to, content: content, as: type, session: nil)
    }

    /// Selects the records whose ids are in `range`.
    public func select<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.select(range: range, as: model, session: nil)
    }

    /// Deletes the records whose ids are in `range`, returning them as they
    /// were.
    public func delete<Model: Decodable & Sendable>(
        range: SurrealRecordRange,
        as model: Model.Type
    ) async throws -> [Model] {
        try await core.delete(range: range, as: model, session: nil)
    }

    /// Calls a server-side function by name, such as `fn::greet` or
    /// `string::len`, with `arguments`. `version` picks a version of a
    /// `DEFINE MODEL` function.
    public func run(_ name: String, version: String? = nil, arguments: [SurrealValue] = []) async throws -> SurrealValue {
        try await core.run(name, version: version, arguments: arguments, session: nil)
    }

    /// Calls a server-side function and decodes its result as `T`.
    public func run<T: Decodable>(
        _ name: String,
        version: String? = nil,
        arguments: [SurrealValue] = [],
        as type: T.Type
    ) async throws -> T {
        try await core.run(name, version: version, arguments: arguments, session: nil).decode(type)
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
        try await core.api(path, method: method, body: body, headers: headers, query: query, session: nil)
    }

    /// Runs a SurrealQL dump, such as one from `export()`, against the
    /// selected database over HTTP (`POST /import`). The dump must start
    /// with `OPTION IMPORT;`, as exports do. The import isn't transactional:
    /// if some statements fail, the rest still apply and this throws
    /// `SurrealError.importFailed` listing the failures.
    public func `import`(_ sql: String) async throws {
        try await core.importSQL(sql, session: nil)
    }

    /// Exports the selected database as SurrealQL over HTTP (`/export`).
    /// With no options, everything is exported.
    public func export(_ options: SurrealExportOptions? = nil) async throws -> String {
        try await core.export(options, session: nil)
    }

    /// Opens an interactive transaction: statements sent through the returned
    /// handle run inside it until you call `commit()` or `cancel()`.
    /// WebSocket only; throws `SurrealError.unsupportedFeature` over HTTP.
    public func beginTransaction() async throws -> SurrealInteractiveTransaction {
        let txn = try await core.beginTransaction(session: nil)
        return SurrealInteractiveTransaction(core: core, session: nil, id: txn)
    }

    /// Runs `body` in an interactive transaction, committing it if `body`
    /// returns and cancelling it if `body` throws.
    public func withTransaction<T: Sendable>(
        _ body: @Sendable (SurrealInteractiveTransaction) async throws -> T
    ) async throws -> T {
        try await core.withTransaction(session: nil, body)
    }

    public func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil,
        limit: Int? = nil,
        start: Int? = nil
    ) async throws -> [Model] {
        try await core.select(model, where: predicate, limit: limit, start: start, session: nil)
    }

    public func create<Model: SurrealModel & Codable & Sendable>(_ value: Model) async throws -> [Model] {
        try await core.create(value, session: nil)
    }

    public func select<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.select(recordID: recordID, as: model, session: nil)
    }

    public func create<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.create(recordID: recordID, content: content, session: nil)
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
        try await core.update(model, content: content, where: predicate, session: nil)
    }

    /// Replaces the content of every record in the table with `content`.
    public func updateAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model] {
        try await core.update(model, content: content, where: nil, session: nil)
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
        try await core.upsert(model, content: content, where: predicate, session: nil)
    }

    /// Replaces the content of every record in the table with `content`.
    public func upsertAll<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model
    ) async throws -> [Model] {
        try await core.upsert(model, content: content, where: nil, session: nil)
    }

    public func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate? = nil
    ) async throws -> [Model] {
        try await core.delete(model, where: predicate, session: nil)
    }

    public func update<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.update(recordID: recordID, content: content, session: nil)
    }

    public func upsert<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model
    ) async throws -> Model? {
        try await core.upsert(recordID: recordID, content: content, session: nil)
    }

    public func delete<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type
    ) async throws -> Model? {
        try await core.delete(recordID: recordID, as: model, session: nil)
    }

    /// Opens a live query stream. Throws `SurrealError.unsupportedFeature` when
    /// the client was created with an HTTP endpoint.
    public func live<T: Decodable & Sendable>(_ query: LiveQuery<T>) async throws -> AsyncStream<LiveEvent<T>> {
        try await core.live(query, session: nil)
    }

    /// Attaches to a live query already running on this connection, such as
    /// one started with a raw `LIVE SELECT`, and streams its notifications,
    /// starting with any that arrived before this call. Unlike `live(_:)`,
    /// the stream finishes on a reconnect: the SDK doesn't know the query,
    /// so it can't re-issue it.
    public func liveOf<T: Decodable & Sendable>(_ queryID: UUID, as type: T.Type) async throws -> AsyncStream<LiveEvent<T>> {
        try await core.liveOf(queryID, session: nil, as: type)
    }

    public func kill(liveQueryID: UUID) async throws {
        try await core.kill(liveQueryID: liveQueryID, session: nil)
    }
}
