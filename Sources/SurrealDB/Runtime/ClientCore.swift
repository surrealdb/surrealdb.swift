import Foundation

actor SurrealClientCore {
    private let engine: any RPCEngine
    private var rootSession: SessionContext
    private var sessions: [SessionID: SessionContext] = [:]
    private var reconnectReplayTask: Task<Void, Never>?
    private var activeReplay: Task<Void, Never>?
    let http: HTTPEndpoints?
    /// Between a successful `connect()` and `close()`. The engines track
    /// this themselves; it's here for the raw HTTP routes, which bypass them.
    private(set) var isConnected = false
    private let checkServerVersion: Bool

    init(
        engine: any RPCEngine,
        sessionContext: SessionContext = .init(),
        http: HTTPEndpoints? = nil,
        checkServerVersion: Bool = false
    ) {
        self.engine = engine
        self.rootSession = sessionContext
        self.http = http
        self.checkServerVersion = checkServerVersion
    }

    /// Whether the server keeps per-session state (namespace, variables) for
    /// us. Over HTTP every request stands alone, so it's all sent each time.
    private var serverKeepsState: Bool {
        engine is any SessionCapableRPCEngine
    }

    func connect() async throws {
        try await engine.connect()

        // Subscribe before anything else awaits: a reconnect during the
        // version check or session setup below would otherwise be dropped,
        // leaving the new socket without the session.
        let reconnects = await (engine as? any LiveRPCEngine)?.reconnectEvents()

        do {
            if checkServerVersion {
                try ServerVersion.check(try await version())
            }
            if serverKeepsState {
                // A SessionContext passed at init only exists locally until
                // it's applied to the new connection.
                try await apply(session: nil, context: rootSession)
            }
        } catch {
            await engine.close()
            throw error
        }
        isConnected = true

        guard let reconnects else {
            return
        }

        reconnectReplayTask?.cancel()
        reconnectReplayTask = Task { [weak self] in
            for await _ in reconnects {
                guard let self else { return }
                await self.beginReplay()
            }
        }
    }

    func close() async {
        isConnected = false
        reconnectReplayTask?.cancel()
        reconnectReplayTask = nil
        await engine.close()
    }

    // MARK: - Session state lookup/mutation

    func sessionContext(for session: SessionID?) throws -> SessionContext {
        guard let session else {
            return rootSession
        }
        guard let context = sessions[session] else {
            throw SurrealError.invalidSession(session)
        }
        return context
    }

    private func setSessionContext(for session: SessionID?, _ mutate: (inout SessionContext) -> Void) {
        if let session {
            guard sessions[session] != nil else { return }
            mutate(&sessions[session]!)
        } else {
            mutate(&rootSession)
        }
    }

    func hasSession(_ id: SessionID) -> Bool {
        sessions[id] != nil
    }

    // MARK: - Session lifecycle

    func createSession(cloneFrom source: SessionID?) async throws -> SessionID {
        guard engine is any SessionCapableRPCEngine else {
            throw SurrealError.unsupportedFeature(
                "Sessions require a WebSocket endpoint (ws:// or wss://); the current endpoint uses HTTP."
            )
        }

        let sourceContext = try sessionContext(for: source)
        let newID = SessionID()

        try await sendAttach(newID)
        sessions[newID] = SessionContext()

        do {
            if source != nil {
                if sourceContext.namespace != nil || sourceContext.database != nil {
                    try await use(namespace: sourceContext.namespace, database: sourceContext.database, session: newID)
                }
                if let token = sourceContext.accessToken {
                    try await authenticate(token, session: newID)
                }
                for (name, value) in sourceContext.variables {
                    try await set(name, value: value, session: newID)
                }
            }
        } catch {
            // Roll back the half-created session: detach server-side (the
            // local entry is still registered here, so performRPC resolves
            // it), then forget it locally. The original error wins.
            _ = try? await performRPC("detach", session: newID)
            sessions.removeValue(forKey: newID)
            throw error
        }

        return newID
    }

    func destroySession(_ id: SessionID) async throws {
        guard engine is any SessionCapableRPCEngine else {
            throw SurrealError.unsupportedFeature(
                "Sessions require a WebSocket endpoint (ws:// or wss://); the current endpoint uses HTTP."
            )
        }

        _ = try await rpc("detach", session: id)
        sessions.removeValue(forKey: id)
    }

    func listSessions() async throws -> [SessionID] {
        guard engine is any SessionCapableRPCEngine else {
            throw SurrealError.unsupportedFeature(
                "Sessions require a WebSocket endpoint (ws:// or wss://); the current endpoint uses HTTP."
            )
        }

        let response = try await rpc("sessions", session: nil)
        guard case .array(let values) = response else {
            throw SurrealError.invalidResponse("Expected an array of session ids.")
        }

        return try values.map { value in
            switch value {
            case .uuid(let uuid):
                return SessionID(uuid)
            case .string(let raw):
                guard let uuid = UUID(uuidString: raw) else {
                    throw SurrealError.invalidResponse("Session id is not a UUID: \(raw)")
                }
                return SessionID(uuid)
            default:
                throw SurrealError.invalidResponse("Unexpected session id format.")
            }
        }
    }

    /// Sends the raw `attach` RPC. Can't route through `performRPC`: the id
    /// isn't registered in `sessions` yet at attach time (and during
    /// reconnect replay, re-attaching must not depend on lookup state).
    private func sendAttach(_ id: SessionID) async throws {
        let request = RPCRequest(id: UUID().uuidString.lowercased(), method: "attach", params: nil, session: id.rawValue.uuidString, txn: nil)
        let envelope = try await engine.send(request, session: rootSession)
        if let error = envelope.error {
            throw SurrealError.serverError(error)
        }
    }

    // MARK: - Reconnect replay

    private func beginReplay() async {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.replayAllSessions()
        }
        activeReplay = task
        await task.value
        activeReplay = nil
    }

    private func replayAllSessions() async {
        await replay(session: nil, context: rootSession)
        for (id, context) in sessions {
            try? await sendAttach(id)
            await replay(session: id, context: context)
        }
    }

    /// Replays a session's stored state onto a freshly reconnected socket.
    /// Uses `performRPC` (not `rpc`) so the replay can't gate on itself, and
    /// skips the local context mutation the public `use`/`authenticate` do —
    /// the stored context already holds exactly the values being replayed.
    private func replay(session: SessionID?, context: SessionContext) async {
        try? await apply(session: session, context: context, stopOnError: false)
    }

    /// Sends a session's namespace, database, token and variables to the
    /// server. Throws on the first failure unless `stopOnError` is false, as
    /// for a reconnect, where one failed step shouldn't skip the rest.
    private func apply(session: SessionID?, context: SessionContext, stopOnError: Bool = true) async throws {
        func step(_ method: String, _ params: [SurrealValue]) async throws {
            do {
                _ = try await performRPC(method, params: params, session: session)
            } catch where !stopOnError {
                return
            }
        }
        if context.namespace != nil || context.database != nil {
            try await step(
                "use",
                [
                    context.namespace.map(SurrealValue.string) ?? .none,
                    context.database.map(SurrealValue.string) ?? .none,
                ]
            )
        }
        if let token = context.accessToken {
            try await step("authenticate", [.string(token)])
        }
        for (name, value) in context.variables {
            try await step("let", [.string(name), value])
        }
    }

    // MARK: - Session-scoped operations

    func use(namespace: String?, database: String?, session: SessionID?) async throws {
        _ = try await rpc(
            "use",
            params: [
                namespace.map(SurrealValue.string) ?? .none,
                database.map(SurrealValue.string) ?? .none,
            ],
            session: session
        )

        setSessionContext(for: session) { context in
            if let namespace {
                context.namespace = namespace
            }
            if let database {
                context.database = database
            }
        }
    }

    func signin(_ credentials: SignInCredentials, session: SessionID?) async throws -> AuthTokens {
        let context = try sessionContext(for: session)
        let payload = try credentials.payload(using: context)
        let response = try await rpc("signin", params: [payload], session: session, anonymous: true)

        let tokens = try parseAuthTokens(response)
        setSessionContext(for: session) { $0.accessToken = tokens.access }
        return tokens
    }

    func signup(_ credentials: SignUpCredentials, session: SessionID?) async throws -> AuthTokens {
        let context = try sessionContext(for: session)
        let payload = try credentials.payload(using: context)
        let response = try await rpc("signup", params: [payload], session: session, anonymous: true)

        let tokens = try parseAuthTokens(response)
        setSessionContext(for: session) { $0.accessToken = tokens.access }
        return tokens
    }

    // signin, signup and authenticate replace the stored token, so they're
    // sent without it: over HTTP a stale one gets the request refused.
    func authenticate(_ token: String, session: SessionID?) async throws {
        _ = try await rpc("authenticate", params: [.string(token)], session: session, anonymous: true)
        setSessionContext(for: session) { $0.accessToken = token }
    }

    func invalidate(session: SessionID?) async throws {
        _ = try await rpc("invalidate", session: session)
        setSessionContext(for: session) { $0.accessToken = nil }
    }

    /// Defines `$name` on the server for this session (`let`). The value is
    /// also kept locally: it's replayed after a reconnect and copied into
    /// forks, and over HTTP, where the server keeps no session state, it's
    /// sent with every query instead.
    func set(_ name: String, value: SurrealValue, session: SessionID?) async throws {
        _ = try sessionContext(for: session)
        if serverKeepsState {
            _ = try await rpc("let", params: [.string(name), value], session: session)
        }
        setSessionContext(for: session) { $0.variables[name] = value }
    }

    func unset(_ name: String, session: SessionID?) async throws {
        _ = try sessionContext(for: session)
        if serverKeepsState {
            _ = try await rpc("unset", params: [.string(name)], session: session)
        }
        setSessionContext(for: session) { $0.variables.removeValue(forKey: name) }
    }

    // MARK: - Server information and auth lifecycle

    /// The server's version, without the `surrealdb-` prefix.
    func version() async throws -> String {
        // Sent without the stored token: over HTTP a stale one would get the
        // request refused before connect() lets the caller re-authenticate.
        let response = try await rpc("version", session: nil, anonymous: true)
        switch response {
        case .string(let raw):
            return ServerVersion.strip(raw)
        case .object(let fields):
            // Newer servers answer { version, build, timestamp }.
            if case .string(let raw)? = fields["version"] {
                return ServerVersion.strip(raw)
            }
        default:
            break
        }
        throw SurrealError.invalidResponse("Expected a version string or object.")
    }

    /// Checks `GET /health`. Throws if the server isn't healthy.
    func health() async throws {
        guard let http else {
            throw SurrealError.unsupportedFeature("health() needs the server's HTTP endpoint.")
        }
        try await http.health()
    }

    /// The record of the signed-in user (`$auth`), or `NONE`.
    func info(session: SessionID?) async throws -> SurrealValue {
        try await rpc("info", session: session)
    }

    /// Exchanges a refresh token for a new token pair. The refresh token is
    /// single-use: the server revokes it.
    func refresh(_ tokens: AuthTokens, session: SessionID?) async throws -> AuthTokens {
        guard tokens.refresh != nil else {
            throw SurrealError.invalidCredentials("refresh() needs a refresh token; sign in with an access method that issues one.")
        }
        // Over HTTP the stored access token goes out as a Bearer header, and
        // the server rejects an expired one before reading the body. Leave it
        // off this request without forgetting it, in case refresh fails.
        let response = try await rpc("refresh", params: [tokens.surrealValue], session: session, anonymous: true)
        let refreshed = try parseAuthTokens(response)
        setSessionContext(for: session) { $0.accessToken = refreshed.access }
        return refreshed
    }

    /// Revokes a refresh token so it can't be used again.
    func revoke(_ tokens: AuthTokens, session: SessionID?) async throws {
        guard tokens.refresh != nil else {
            throw SurrealError.invalidCredentials("revoke() needs a refresh token.")
        }
        // As for refresh: an expired access token must not block revoking.
        _ = try await rpc("revoke", params: [tokens.surrealValue], session: session, anonymous: true)
    }

    /// Authenticates with a token pair. If the access token has expired and
    /// there's a refresh token, refreshes the pair and returns the new one.
    func authenticate(_ tokens: AuthTokens, session: SessionID?) async throws -> AuthTokens {
        if tokens.refresh != nil, let expiry = tokens.accessExpiry, expiry <= Date() {
            return try await refresh(tokens, session: session)
        }
        do {
            try await authenticate(tokens.access, session: session)
            return tokens
        } catch let error as SurrealError where tokens.refresh != nil && error.isTokenExpired {
            // Expired between the check above and the server seeing it.
            return try await refresh(tokens, session: session)
        }
    }

    /// Clears the session on the server: namespace, database, authentication
    /// and variables.
    func reset(session: SessionID?) async throws {
        if serverKeepsState {
            _ = try await rpc("reset", session: session)
        }
        setSessionContext(for: session) { $0 = SessionContext() }
    }

    func queryRaw(_ sql: String, bindings: [String: SurrealValue], session: SessionID?, txn: UUID? = nil) async throws -> [RPCQueryResult] {
        let context = try sessionContext(for: session)
        var mergedBindings = serverKeepsState ? [:] : context.variables
        for (key, value) in bindings {
            mergedBindings[key] = value
        }

        let response = try await rpc(
            "query",
            params: [
                .string(sql),
                .object(mergedBindings),
            ],
            session: session,
            txn: txn
        )

        return try RPCWire.decodeQueryResults(from: response)
    }

    func transaction(
        _ build: (SurrealTransaction) throws -> Void,
        session: SessionID?
    ) async throws -> [RPCQueryResult] {
        let tx = SurrealTransaction()
        try build(tx)
        let (sql, bindings) = tx.build()
        return try await queryRaw(sql, bindings: bindings, session: session)
    }

    func query<T: Decodable & Sendable>(_ query: SurrealQuery<T>, session: SessionID?, txn: UUID? = nil) async throws -> [T] {
        let results = try await queryRaw(query.sql, bindings: query.bindings, session: session, txn: txn)
        return try decodeQueryResults(results, as: T.self)
    }

    func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate?,
        limit: Int?,
        start: Int?,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        let query = SurrealDSL.select(model, where: predicate, limit: limit, start: start)
        return try await self.query(query, session: session, txn: txn)
    }

    func create<Model: SurrealModel & Codable & Sendable>(_ value: Model, session: SessionID?, txn: UUID? = nil) async throws -> [Model] {
        let content = try SurrealValue.fromEncodable(value)
        let query = SurrealDSL.create(Model.self, bindings: ["content": content])
        return try await self.query(query, session: session, txn: txn)
    }

    /// Record ids are always sent as bound values, never spliced into the
    /// statement text.
    private static let recordBinding = "_sdk_record"

    func select<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> Model? {
        let query = SurrealQuery<Model>(sql: "SELECT * FROM type::record($\(Self.recordBinding));", bindings: [Self.recordBinding: .recordID(recordID)])
        return try await self.query(query, session: session, txn: txn).first
    }

    func create<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> Model? {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealQuery<Model>(
            sql: "CREATE type::record($\(Self.recordBinding)) CONTENT $content;",
            bindings: [Self.recordBinding: .recordID(recordID), "content": payload]
        )
        return try await self.query(query, session: session, txn: txn).first
    }

    func update<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate?,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealDSL.update(model, where: predicate, bindings: ["content": payload])
        return try await self.query(query, session: session, txn: txn)
    }

    func upsert<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate?,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        let payload = try SurrealValue.fromEncodable(content)
        // A table-wide UPSERT with no WHERE inserts one new record rather
        // than touching the existing ones; `WHERE true` updates them all.
        let query = SurrealDSL.upsert(model, where: predicate ?? SurrealPredicate(raw: "true"), bindings: ["content": payload])
        return try await self.query(query, session: session, txn: txn)
    }

    func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate?,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> [Model] {
        let query = SurrealDSL.delete(model, where: predicate)
        return try await self.query(query, session: session, txn: txn)
    }

    func update<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> Model? {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealQuery<Model>(
            sql: "UPDATE type::record($\(Self.recordBinding)) CONTENT $content;",
            bindings: [Self.recordBinding: .recordID(recordID), "content": payload]
        )
        return try await self.query(query, session: session, txn: txn).first
    }

    func upsert<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> Model? {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealQuery<Model>(
            sql: "UPSERT type::record($\(Self.recordBinding)) CONTENT $content;",
            bindings: [Self.recordBinding: .recordID(recordID), "content": payload]
        )
        return try await self.query(query, session: session, txn: txn).first
    }

    func delete<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type,
        session: SessionID?,
        txn: UUID? = nil
    ) async throws -> Model? {
        let query = SurrealQuery<Model>(sql: "DELETE type::record($\(Self.recordBinding));", bindings: [Self.recordBinding: .recordID(recordID)])
        return try await self.query(query, session: session, txn: txn).first
    }

    /// Opens an interactive transaction (`begin`) and returns its id.
    /// Statements sent with that id in `txn` run inside it until `commit` or
    /// `cancel`. The server only allows this over WebSocket.
    func beginTransaction(session: SessionID?) async throws -> UUID {
        _ = try sessionContext(for: session)
        guard serverKeepsState else {
            throw SurrealError.unsupportedFeature(
                "Interactive transactions need a WebSocket connection. Over HTTP, use transaction { } to send the statements as one BEGIN ... COMMIT query."
            )
        }
        // Sent from a task of its own: if the caller is cancelled after the
        // server has opened the transaction, its id still comes back, and the
        // transaction is cancelled rather than left open. (A timeout resets
        // the socket, which ends every transaction on it.)
        let response = try await Task { try await self.rpc("begin", session: session) }.value
        var opened: UUID?
        switch response {
        case .uuid(let id):
            opened = id
        case .string(let text):
            opened = UUID(uuidString: text)
        default:
            break
        }
        guard let id = opened else {
            throw SurrealError.invalidResponse("Expected a transaction id from begin, got \(response.kindName).")
        }
        if Task.isCancelled {
            _ = await Task { try? await self.rpc("cancel", params: [.uuid(id)], session: session) }.value
            throw CancellationError()
        }
        return id
    }

    func commitTransaction(_ id: UUID, session: SessionID?) async throws {
        _ = try await rpc("commit", params: [.uuid(id)], session: session)
    }

    func cancelTransaction(_ id: UUID, session: SessionID?) async throws {
        _ = try await rpc("cancel", params: [.uuid(id)], session: session)
    }

    func kill(liveQueryID: UUID, session: SessionID?) async throws {
        _ = try await rpc("kill", params: [.uuid(liveQueryID)], session: session)
    }

    func rpc(_ method: String, params: [SurrealValue]? = nil, session: SessionID?, txn: UUID? = nil, anonymous: Bool = false) async throws -> SurrealValue {
        if let activeReplay {
            await activeReplay.value
        }

        return try await performRPC(method, params: params, session: session, txn: txn, anonymous: anonymous)
    }

    /// Ungated variant of `rpc`. The reconnect-replay path must use this
    /// directly: its own `use`/`authenticate` calls would otherwise hit the
    /// `activeReplay` gate above and await the replay task from within the
    /// replay task — deadlocking the whole client.
    /// `anonymous` leaves the stored access token off this one request (the
    /// HTTP engine sends it as a Bearer header).
    private func performRPC(_ method: String, params: [SurrealValue]? = nil, session: SessionID?, txn: UUID? = nil, anonymous: Bool = false) async throws -> SurrealValue {
        var context = try sessionContext(for: session)
        if anonymous {
            context.accessToken = nil
        }
        let request = RPCRequest(
            id: UUID().uuidString.lowercased(),
            method: method,
            params: params,
            session: session?.rawValue.uuidString,
            txn: txn?.uuidString.lowercased()
        )

        let envelope = try await engine.send(request, session: context)

        if let error = envelope.error {
            throw SurrealError.serverError(error)
        }

        return envelope.result ?? .null
    }

    private func parseAuthTokens(_ value: SurrealValue) throws -> AuthTokens {
        switch value {
        case .string(let token):
            return .init(access: token)
        case .object(let payload):
            let access = payload["access"].flatMap(extractString(_:))
                ?? payload["token"].flatMap(extractString(_:))
            guard let access else {
                throw SurrealError.invalidResponse("Missing access token in auth response.")
            }

            let refresh = payload["refresh"].flatMap(extractString(_:))
            return .init(access: access, refresh: refresh)
        default:
            throw SurrealError.invalidResponse("Unexpected auth response format.")
        }
    }

    private func extractString(_ value: SurrealValue) -> String? {
        if case .string(let string) = value {
            return string
        }
        return nil
    }

    private func decodeQueryResults<T: Decodable & Sendable>(
        _ results: [RPCQueryResult],
        as type: T.Type
    ) throws -> [T] {
        var decoded: [T] = []
        var errors: [QueryErrorDetail] = []

        for (index, row) in results.enumerated() {
            if row.status == .err {
                errors.append(
                    QueryErrorDetail(index: index, message: row.errorMessage, kind: row.kind, details: row.details)
                )
                continue
            }

            switch row.result {
            case .array(let array):
                for element in array {
                    decoded.append(try element.decode(T.self))
                }
            case .null, .none:
                continue
            default:
                decoded.append(try row.result.decode(T.self))
            }
        }

        if !errors.isEmpty {
            throw SurrealError.queryErrors(errors)
        }

        return decoded
    }
}

extension SurrealClientCore {
    func live<T: Decodable & Sendable>(_ query: LiveQuery<T>, session: SessionID?) async throws -> AsyncStream<LiveEvent<T>> {
        guard let liveEngine = engine as? any LiveRPCEngine else {
            throw SurrealError.unsupportedFeature(
                "Live queries require a WebSocket endpoint (ws:// or wss://); the current endpoint uses HTTP."
            )
        }

        let queryID = try await registerLiveQuery(query, session: session)
        let wireStream = await liveEngine.openLiveStream(for: queryID)

        let killed = KilledFlag()
        return AsyncStream { continuation in
            let forwardTask = Task {
                for await event in wireStream {
                    let decoded = event.action == .killed ? nil : try? event.payload.decode(T.self)
                    var record: SurrealRecordID?
                    switch event.record {
                    case .recordID(let id)?:
                        record = id
                    case .string(let text)?:
                        // The JSON wire format sends record ids as text.
                        record = SurrealRecordID(parsing: text)
                    default:
                        break
                    }
                    continuation.yield(
                        LiveEvent(
                            queryID: event.queryID,
                            action: event.action,
                            recordID: event.recordID,
                            record: record,
                            rawPayload: event.payload,
                            decoded: decoded
                        )
                    )
                    if event.action == .killed {
                        // The server has already dropped it; don't KILL again.
                        killed.set()
                        break
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { [queryID] _ in
                forwardTask.cancel()
                Task {
                    if !killed.isSet {
                        try? await self.kill(liveQueryID: queryID, session: session)
                    }
                    await liveEngine.closeLiveStream(for: queryID)
                }
            }
        }
    }

    private func registerLiveQuery<T: Decodable & Sendable>(_ query: LiveQuery<T>, session: SessionID?) async throws -> UUID {
        let results = try await queryRaw(query.sql, bindings: query.bindings, session: session)

        guard let first = results.first else {
            throw SurrealError.invalidResponse("Expected live query registration result.")
        }

        let candidate = first.result
        switch candidate {
        case .uuid(let uuid):
            return uuid
        case .string(let raw):
            if let uuid = UUID(uuidString: raw) {
                return uuid
            }
            throw SurrealError.invalidResponse("Live query id is not a UUID: \(raw)")
        case .array(let rows):
            if let first = rows.first {
                if case .uuid(let uuid) = first {
                    return uuid
                }
                if case .string(let raw) = first, let uuid = UUID(uuidString: raw) {
                    return uuid
                }
            }
            throw SurrealError.invalidResponse("Unable to parse live query identifier.")
        default:
            throw SurrealError.invalidResponse("Unexpected live query registration format.")
        }
    }
}

/// Set once a live stream has seen `KILLED`.
private final class KilledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
