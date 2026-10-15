import Foundation

actor SurrealClientCore {
    private let engine: any RPCEngine
    private var rootSession: SessionContext
    private var sessions: [SessionID: SessionContext] = [:]
    private var reconnectReplayTask: Task<Void, Never>?
    private var activeReplay: Task<Void, Never>?

    init(engine: any RPCEngine, sessionContext: SessionContext = .init()) {
        self.engine = engine
        self.rootSession = sessionContext
    }

    func connect() async throws {
        try await engine.connect()

        guard let liveEngine = engine as? any LiveRPCEngine else {
            return
        }

        // Subscribe before returning, not inside the task: otherwise a
        // reconnect that fires between connect() returning and the task
        // starting is silently dropped.
        let stream = await liveEngine.reconnectEvents()

        reconnectReplayTask?.cancel()
        reconnectReplayTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.beginReplay()
            }
        }
    }

    func close() async {
        reconnectReplayTask?.cancel()
        reconnectReplayTask = nil
        await engine.close()
    }

    // MARK: - Session state lookup/mutation

    private func sessionContext(for session: SessionID?) throws -> SessionContext {
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
                sessions[newID]?.variables = sourceContext.variables
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
        let request = RPCRequest(id: UUID().uuidString, method: "attach", params: nil, session: id.rawValue.uuidString, txn: nil)
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
        if context.namespace != nil || context.database != nil {
            _ = try? await performRPC(
                "use",
                params: [
                    context.namespace.map(SurrealValue.string) ?? .none,
                    context.database.map(SurrealValue.string) ?? .none,
                ],
                session: session
            )
        }
        if let token = context.accessToken {
            _ = try? await performRPC("authenticate", params: [.string(token)], session: session)
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
        let response = try await rpc("signin", params: [payload], session: session)

        let tokens = try parseAuthTokens(response)
        setSessionContext(for: session) { $0.accessToken = tokens.access }
        return tokens
    }

    func signup(_ credentials: SignUpCredentials, session: SessionID?) async throws -> AuthTokens {
        let context = try sessionContext(for: session)
        let payload = try credentials.payload(using: context)
        let response = try await rpc("signup", params: [payload], session: session)

        let tokens = try parseAuthTokens(response)
        setSessionContext(for: session) { $0.accessToken = tokens.access }
        return tokens
    }

    func authenticate(_ token: String, session: SessionID?) async throws {
        _ = try await rpc("authenticate", params: [.string(token)], session: session)
        setSessionContext(for: session) { $0.accessToken = token }
    }

    func invalidate(session: SessionID?) async throws {
        _ = try await rpc("invalidate", session: session)
        setSessionContext(for: session) { $0.accessToken = nil }
    }

    func set(_ name: String, value: SurrealValue, session: SessionID?) async throws {
        _ = try sessionContext(for: session)
        setSessionContext(for: session) { $0.variables[name] = value }
    }

    func unset(_ name: String, session: SessionID?) async throws {
        _ = try sessionContext(for: session)
        setSessionContext(for: session) { $0.variables.removeValue(forKey: name) }
    }

    func queryRaw(_ sql: String, bindings: [String: SurrealValue], session: SessionID?) async throws -> [RPCQueryResult] {
        let context = try sessionContext(for: session)
        var mergedBindings = context.variables
        for (key, value) in bindings {
            mergedBindings[key] = value
        }

        let response = try await rpc(
            "query",
            params: [
                .string(sql),
                .object(mergedBindings),
            ],
            session: session
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

    func query<T: Decodable & Sendable>(_ query: SurrealQuery<T>, session: SessionID?) async throws -> [T] {
        let results = try await queryRaw(query.sql, bindings: query.bindings, session: session)
        return try decodeQueryResults(results, as: T.self)
    }

    func select<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate?,
        limit: Int?,
        start: Int?,
        session: SessionID?
    ) async throws -> [Model] {
        let query = SurrealDSL.select(model, where: predicate, limit: limit, start: start)
        return try await self.query(query, session: session)
    }

    func create<Model: SurrealModel & Codable & Sendable>(_ value: Model, session: SessionID?) async throws -> [Model] {
        let content = try SurrealValue.fromEncodable(value)
        let query = SurrealDSL.create(Model.self, bindings: ["content": content])
        return try await self.query(query, session: session)
    }

    /// Record ids are always sent as bound values, never spliced into the
    /// statement text.
    private static let recordBinding = "_sdk_record"

    func select<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type,
        session: SessionID?
    ) async throws -> Model? {
        let query = SurrealQuery<Model>(sql: "SELECT * FROM type::record($\(Self.recordBinding));", bindings: [Self.recordBinding: .recordID(recordID)])
        return try await self.query(query, session: session).first
    }

    func create<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model,
        session: SessionID?
    ) async throws -> Model? {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealQuery<Model>(
            sql: "CREATE type::record($\(Self.recordBinding)) CONTENT $content;",
            bindings: [Self.recordBinding: .recordID(recordID), "content": payload]
        )
        return try await self.query(query, session: session).first
    }

    func update<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate?,
        session: SessionID?
    ) async throws -> [Model] {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealDSL.update(model, where: predicate, bindings: ["content": payload])
        return try await self.query(query, session: session)
    }

    func upsert<Model: SurrealModel & Codable & Sendable>(
        _ model: Model.Type,
        content: Model,
        where predicate: SurrealPredicate?,
        session: SessionID?
    ) async throws -> [Model] {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealDSL.upsert(model, where: predicate, bindings: ["content": payload])
        return try await self.query(query, session: session)
    }

    func delete<Model: SurrealModel & Decodable & Sendable>(
        _ model: Model.Type,
        where predicate: SurrealPredicate?,
        session: SessionID?
    ) async throws -> [Model] {
        let query = SurrealDSL.delete(model, where: predicate)
        return try await self.query(query, session: session)
    }

    func update<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model,
        session: SessionID?
    ) async throws -> Model? {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealQuery<Model>(
            sql: "UPDATE type::record($\(Self.recordBinding)) CONTENT $content;",
            bindings: [Self.recordBinding: .recordID(recordID), "content": payload]
        )
        return try await self.query(query, session: session).first
    }

    func upsert<Model: SurrealModel & Codable & Sendable>(
        recordID: SurrealRecordID,
        content: Model,
        session: SessionID?
    ) async throws -> Model? {
        let payload = try SurrealValue.fromEncodable(content)
        let query = SurrealQuery<Model>(
            sql: "UPSERT type::record($\(Self.recordBinding)) CONTENT $content;",
            bindings: [Self.recordBinding: .recordID(recordID), "content": payload]
        )
        return try await self.query(query, session: session).first
    }

    func delete<Model: SurrealModel & Decodable & Sendable>(
        recordID: SurrealRecordID,
        as model: Model.Type,
        session: SessionID?
    ) async throws -> Model? {
        let query = SurrealQuery<Model>(sql: "DELETE type::record($\(Self.recordBinding));", bindings: [Self.recordBinding: .recordID(recordID)])
        return try await self.query(query, session: session).first
    }

    func kill(liveQueryID: UUID, session: SessionID?) async throws {
        _ = try await rpc("kill", params: [.uuid(liveQueryID)], session: session)
    }

    private func rpc(_ method: String, params: [SurrealValue]? = nil, session: SessionID?) async throws -> SurrealValue {
        if let activeReplay {
            await activeReplay.value
        }

        return try await performRPC(method, params: params, session: session)
    }

    /// Ungated variant of `rpc`. The reconnect-replay path must use this
    /// directly: its own `use`/`authenticate` calls would otherwise hit the
    /// `activeReplay` gate above and await the replay task from within the
    /// replay task — deadlocking the whole client.
    private func performRPC(_ method: String, params: [SurrealValue]? = nil, session: SessionID?) async throws -> SurrealValue {
        let context = try sessionContext(for: session)
        let request = RPCRequest(
            id: UUID().uuidString,
            method: method,
            params: params,
            session: session?.rawValue.uuidString,
            txn: nil
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
                let message: String
                if case .string(let queryError) = row.result {
                    message = queryError
                } else {
                    message = "Unknown query error"
                }
                errors.append(
                    QueryErrorDetail(index: index, message: message, kind: row.kind, details: row.details)
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

        return AsyncStream { continuation in
            let forwardTask = Task {
                for await event in wireStream {
                    let decoded = try? event.payload.decode(T.self)
                    continuation.yield(
                        LiveEvent(
                            queryID: event.queryID,
                            action: event.action,
                            recordID: event.recordID,
                            rawPayload: event.payload,
                            decoded: decoded
                        )
                    )
                }
                continuation.finish()
            }

            continuation.onTermination = { [queryID] _ in
                forwardTask.cancel()
                Task {
                    try? await self.kill(liveQueryID: queryID, session: session)
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
