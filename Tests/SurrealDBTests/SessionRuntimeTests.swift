import Foundation
import Testing
@testable import SurrealDB

// Runtime coverage for the multi-session machinery against a mock engine:
// attach/detach lifecycle, fork state replication, listSessions parsing,
// rollback on partial failure, and reconnect replay — including a regression
// test for the replay self-deadlock (rpc() gating on the replay task from
// within the replay task).

private actor MockSessionEngine: LiveRPCEngine, SessionCapableRPCEngine {
    struct Recorded: Sendable {
        let method: String
        let session: String?
        let params: [SurrealValue]?
    }

    private(set) var requests: [Recorded] = []
    private var reconnectContinuation: AsyncStream<Void>.Continuation?
    private var failingMethods: Set<String> = []
    private var heldMethods: Set<String> = []
    private var holds: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var sessionsResult: [SurrealValue] = []

    func connect() async throws {}
    func close() async {}

    func failNext(_ method: String) { failingMethods.insert(method) }
    func holdResponses(for method: String) { heldMethods.insert(method) }

    func releaseResponses(for method: String) {
        heldMethods.remove(method)
        for continuation in holds.removeValue(forKey: method) ?? [] {
            continuation.resume()
        }
    }

    func setSessionsResult(_ values: [SurrealValue]) {
        sessionsResult = values
    }

    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        requests.append(.init(method: request.method, session: request.session, params: request.params))

        if heldMethods.contains(request.method) {
            await withCheckedContinuation { continuation in
                holds[request.method, default: []].append(continuation)
            }
        }

        if failingMethods.remove(request.method) != nil {
            return RPCResponseEnvelope(
                id: request.id,
                action: nil,
                result: nil,
                error: RPCErrorObject(code: nil, kind: "Internal", message: "injected failure", details: nil, cause: nil)
            )
        }

        switch request.method {
        case "query":
            let row: SurrealValue = .object([
                "status": .string("OK"),
                "time": .string("0ms"),
                "result": .array([]),
            ])
            return RPCResponseEnvelope(id: request.id, action: nil, result: .array([row]), error: nil)
        case "sessions":
            return RPCResponseEnvelope(id: request.id, action: nil, result: .array(sessionsResult), error: nil)
        default:
            return RPCResponseEnvelope(id: request.id, action: nil, result: .null, error: nil)
        }
    }

    func openLiveStream(for queryID: UUID) async -> AsyncStream<LiveWireEvent> {
        AsyncStream { $0.finish() }
    }

    func closeLiveStream(for queryID: UUID) async {}
    func moveLiveStream(from oldID: UUID, to newID: UUID) async {}

    func reconnectEvents() -> AsyncStream<Void> {
        reconnectContinuation?.finish()
        return AsyncStream { continuation in
            self.reconnectContinuation = continuation
        }
    }

    func fireReconnect() { reconnectContinuation?.yield(()) }
    func hasSubscriber() -> Bool { reconnectContinuation != nil }

    func methods() -> [String] { requests.map(\.method) }
    func count(of method: String) -> Int { requests.filter { $0.method == method }.count }
    func request(_ method: String) -> Recorded? { requests.first { $0.method == method } }
    func lastRequest(_ method: String) -> Recorded? { requests.last { $0.method == method } }
}

/// A minimal engine that is neither live nor session-capable (HTTP-like).
private actor MockPlainEngine: RPCEngine {
    func connect() async throws {}
    func close() async {}
    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        RPCResponseEnvelope(id: request.id, action: nil, result: .null, error: nil)
    }
}

private func withTimeout<T: Sendable>(
    seconds: Double = 5,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SurrealError.timeout
        }
        guard let value = try await group.next() else {
            throw SurrealError.timeout
        }
        group.cancelAll()
        return value
    }
}

private func waitUntil(
    seconds: Double = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw SurrealError.timeout
}

@Test
func core_createSessionSendsAttachAndRegistersLocally() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()

    let id = try await core.createSession(cloneFrom: nil)

    let attach = await engine.request("attach")
    #expect(attach != nil)
    #expect(attach?.session == id.rawValue.uuidString)
    let registered = await core.hasSession(id)
    #expect(registered)

    try await core.use(namespace: "ns", database: "db", session: id)
    let use = await engine.request("use")
    #expect(use?.session == id.rawValue.uuidString)
}

@Test
func core_forkSessionReplicatesStateOntoNewSession() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()

    let parent = try await core.createSession(cloneFrom: nil)
    try await core.use(namespace: "ns", database: "db", session: parent)
    try await core.authenticate("parent-token", session: parent)
    try await core.set("marker", value: .string("inherited"), session: parent)

    let child = try await core.createSession(cloneFrom: parent)
    let registered = await core.hasSession(child)
    #expect(registered)

    // The fork re-attached, re-selected ns/db, and re-authenticated the child.
    let childID = child.rawValue.uuidString
    let lastAttach = await engine.lastRequest("attach")
    let lastUse = await engine.lastRequest("use")
    let lastAuthenticate = await engine.lastRequest("authenticate")
    #expect(lastAttach?.session == childID)
    #expect(lastUse?.session == childID)
    #expect(lastAuthenticate?.session == childID)

    // Variables were copied: the child gets its own server-side `let`.
    let lastLet = await engine.lastRequest("let")
    #expect(lastLet?.session == childID)
    #expect(lastLet?.params == [.string("marker"), .string("inherited")])
}

@Test
func core_destroySessionDetachesAndInvalidates() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()

    let id = try await core.createSession(cloneFrom: nil)
    try await core.destroySession(id)

    let detach = await engine.request("detach")
    #expect(detach?.session == id.rawValue.uuidString)
    let stillRegistered = await core.hasSession(id)
    #expect(!stillRegistered)

    await #expect(throws: SurrealError.self) {
        try await core.use(namespace: "ns", database: "db", session: id)
    }
}

@Test
func core_destroySessionOnPlainEngineThrowsUnsupportedFeature() async throws {
    let core = SurrealClientCore(engine: MockPlainEngine())
    try await core.connect()

    do {
        try await core.destroySession(SessionID())
        Issue.record("Expected destroySession to throw on a non-session engine")
    } catch SurrealError.unsupportedFeature {
        // expected: transport gating, not invalidSession
    }
}

@Test
func core_createSessionRollsBackWhenReplicationFails() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()

    let parent = try await core.createSession(cloneFrom: nil)
    try await core.use(namespace: "ns", database: "db", session: parent)

    await engine.failNext("use")

    do {
        _ = try await core.createSession(cloneFrom: parent)
        Issue.record("Expected fork to throw when its use replay fails")
    } catch {
        // The half-created session was detached server-side and forgotten
        // locally; only the parent remains.
        let detachCount = await engine.count(of: "detach")
        #expect(detachCount == 1)
        let detachedSession = await engine.lastRequest("detach")?.session
        #expect(detachedSession != parent.rawValue.uuidString)
        let parentStillRegistered = await core.hasSession(parent)
        #expect(parentStillRegistered)
    }
}

@Test
func core_listSessionsParsesUUIDAndStringValues() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()

    let a = UUID()
    let b = UUID()
    await engine.setSessionsResult([.uuid(a), .string(b.uuidString)])

    let ids = try await core.listSessions()
    #expect(ids == [SessionID(a), SessionID(b)])

    await engine.setSessionsResult([.int(5)])
    await #expect(throws: SurrealError.self) {
        _ = try await core.listSessions()
    }
}

@Test
func core_reconnectReplayRestoresStateWithoutDeadlockingAndGatesCalls() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(
        engine: engine,
        sessionContext: SessionContext(namespace: "ns", database: "db", accessToken: "token")
    )
    try await core.connect()
    try await waitUntil { await engine.hasSubscriber() }
    // connect() applies the initial context: one use and one authenticate.
    #expect(await engine.methods() == ["use", "authenticate"])

    // Park the replay's first RPC so we can observe the gate deterministically.
    await engine.holdResponses(for: "use")
    await engine.fireReconnect()
    try await waitUntil { await engine.count(of: "use") == 2 }

    // A call issued mid-replay must wait behind the replay, not race it.
    let query = Task {
        try await core.queryRaw("RETURN 1;", bindings: [:], session: nil)
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    let queriesDuringReplay = await engine.count(of: "query")
    #expect(queriesDuringReplay == 0)

    await engine.releaseResponses(for: "use")

    // Regression guard for the replay self-deadlock: this completes (or the
    // timeout fails the test) instead of hanging CI.
    let rows = try await withTimeout { try await query.value }
    #expect(rows.count == 1)

    let methods = await engine.methods()
    #expect(methods == ["use", "authenticate", "use", "authenticate", "query"])
}

@Test
func core_reconnectReplayReattachesForkedSessions() async throws {
    let engine = MockSessionEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()
    try await waitUntil { await engine.hasSubscriber() }

    let id = try await core.createSession(cloneFrom: nil)
    try await core.use(namespace: "ns", database: "db", session: id)
    let attachesBefore = await engine.count(of: "attach")

    await engine.fireReconnect()
    try await waitUntil { await engine.count(of: "attach") == attachesBefore + 1 }

    // The session was re-attached and its namespace/database replayed.
    let lastAttach = await engine.lastRequest("attach")
    #expect(lastAttach?.session == id.rawValue.uuidString)
    try await waitUntil { await engine.count(of: "use") == 2 }
    let lastUse = await engine.lastRequest("use")
    #expect(lastUse?.session == id.rawValue.uuidString)
}
