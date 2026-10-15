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

        let transport: any RPCEngine
        switch rpcURL.scheme?.lowercased() {
        case "ws", "wss":
            self.engine = .webSocket
            transport = WebSocketRPCEngine(
                endpoint: rpcURL,
                clientOptions: options,
                wsOptions: websocketOptions,
                codec: codec
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

        self.core = SurrealClientCore(engine: transport, sessionContext: session)
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

    public func kill(liveQueryID: UUID) async throws {
        try await core.kill(liveQueryID: liveQueryID, session: nil)
    }
}
