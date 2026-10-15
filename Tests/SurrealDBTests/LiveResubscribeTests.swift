import Foundation
import Testing
@testable import SurrealDB

private struct Note: SurrealModel, Codable, Sendable, Equatable {
    static let surrealTable = "note"
    var id: SurrealRecordID?
    var text: String
    var n: Int
}

/// Collects a live stream's events so a test can wait for them.
private final class Collected<T: Decodable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveEvent<T>] = []
    private var finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LiveEvent<T>>) {
        task = Task {
            for await event in stream {
                self.append(event)
            }
            self.finish()
        }
    }

    private func append(_ event: LiveEvent<T>) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var snapshot: [LiveEvent<T>] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func cancel() {
        task?.cancel()
    }
}

@Test
func patchOperation_decodesFromDiffs() throws {
    let ops = try SurrealValue.array([
        .object(["op": .string("replace"), "path": .string("/n"), "value": .int(2)]),
        .object(["op": .string("change"), "path": .string("/text"), "value": .string("@@ -1 +1 @@\n-a\n+b\n")]),
        .object(["op": .string("remove"), "path": .string("/old")]),
        .object(["op": .string("move"), "from": .string("/a"), "path": .string("/b")]),
    ]).decode([SurrealPatchOperation].self)
    #expect(ops == [
        .replace(path: "/n", value: .int(2)),
        .change(path: "/text", value: "@@ -1 +1 @@\n-a\n+b\n"),
        .remove(path: "/old"),
        .move(from: "/a", path: "/b"),
    ])
    #expect(throws: (any Error).self) {
        _ = try SurrealValue.object(["op": .string("frobnicate"), "path": .string("/")]).decode(SurrealPatchOperation.self)
    }
}

@Test
func integration_liveOfDeliversNotificationsSentBeforeAttaching() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    // Started with raw SurrealQL: nothing is listening yet when the
    // notifications arrive.
    guard case .uuid(let queryID)? = try await client.queryRaw("LIVE SELECT * FROM note;").first?.result else {
        Issue.record("Expected a live query id")
        return
    }
    _ = try await client.create(Note(id: nil, text: "early", n: 1))
    _ = try await client.queryRaw("RETURN 1;")  // let the notification arrive

    let collected = Collected(try await client.liveOf(queryID, as: Note.self))
    defer { collected.cancel() }
    _ = try await client.create(Note(id: nil, text: "late", n: 2))

    #expect(await eventually { collected.snapshot.count == 2 })
    #expect(collected.snapshot.map { $0.decoded?.text } == ["early", "late"])
    #expect(collected.snapshot.allSatisfy { $0.queryID == queryID })
}

@Test
func integration_liveQueriesResubscribeAfterReconnect() async throws {
    guard IntegrationEnv.canProxy else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    let client = try await integrationClient("ws://127.0.0.1:\(proxy.port)", websocketOptions: .init(reconnectBaseDelay: 0.05))
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    let live = Collected(try await client.live(SurrealDSL.live(Note.self, where: SurrealField<Note, Int>("n") > 0)))
    defer { live.cancel() }
    guard case .uuid(let rawID)? = try await client.queryRaw("LIVE SELECT * FROM note;").first?.result else {
        Issue.record("Expected a live query id")
        return
    }
    let attached = Collected(try await client.liveOf(rawID, as: Note.self))
    defer { attached.cancel() }

    _ = try await client.create(Note(id: nil, text: "before", n: 1))
    #expect(await eventually { live.snapshot.count == 1 && attached.snapshot.count == 1 })
    let firstID = try #require(live.snapshot.first?.queryID)

    proxy.dropConnections()
    let recovered = await eventually {
        (try? await client.queryRaw("RETURN 1;").first?.result) == .int(1)
    }
    #expect(recovered)

    // The same stream carries on, under the re-issued query's new id, with
    // its predicate (and its bindings) intact.
    _ = try await client.create(Note(id: nil, text: "skipped", n: 0))
    _ = try await client.create(Note(id: nil, text: "after", n: 2))
    #expect(await eventually { live.snapshot.count == 2 })
    #expect(live.snapshot.map { $0.decoded?.text } == ["before", "after"])
    #expect(live.snapshot.last?.queryID != firstID)
    #expect(!live.isFinished)

    // A stream attached with liveOf can't be re-issued, so it finished.
    #expect(await eventually { attached.isFinished })
    #expect(attached.snapshot.count == 1)

    // Ending the stream kills the re-issued query on the server.
    live.cancel()
    let newID = try #require(live.snapshot.last?.queryID)
    #expect(await eventually {
        do {
            try await client.kill(liveQueryID: newID)
            return false
        } catch {
            return true
        }
    })
}

@Test
func integration_liveDiffSendsPatchOperations() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    let collected = Collected(try await client.live(SurrealDSL.liveDiff(Note.self)))
    defer { collected.cancel() }

    let id = SurrealRecordID(table: "note", id: .string("d"))
    _ = try await client.create(recordID: id, content: Note(id: nil, text: "hello world", n: 1))
    _ = try await client.merge(recordID: id, with: ["text": SurrealValue.string("hello there world"), "n": .int(2)], as: Note.self)

    #expect(await eventually { collected.snapshot.count == 2 })
    // The server doesn't promise to send notifications from separate
    // requests in order, so look them up by action.
    let events = collected.snapshot
    #expect(Set(events.map(\.action)) == [.create, .update])
    #expect(events.allSatisfy { $0.record == id })
    let changes = try #require(events.first { $0.action == .update }?.decoded)
    #expect(changes.contains(.replace(path: "/n", value: .int(2))))
    #expect(changes.contains { if case .change(path: "/text", _) = $0 { return true } else { return false } })
}

@Test
func integration_explicitConnectDuringRecoveryReissuesLiveQueries() async throws {
    guard IntegrationEnv.canProxy else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    // Automatic recovery waits a minute, so the explicit connect() wins.
    let client = try await integrationClient("ws://127.0.0.1:\(proxy.port)", websocketOptions: .init(reconnectBaseDelay: 60))
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")
    let live = Collected(try await client.live(SurrealDSL.live(Note.self)))
    defer { live.cancel() }

    proxy.dropConnections()
    #expect(await eventually { (try? await client.queryRaw("RETURN 1;")) == nil })
    try await client.connect()

    _ = try await client.create(Note(id: nil, text: "after", n: 1))
    #expect(await eventually { live.snapshot.map(\.decoded?.text) == ["after"] }, "\(live.snapshot.map { "\($0.action) \($0.decoded?.text ?? "-")" }) finished=\(live.isFinished)")
}

@Test
func integration_reissuedLiveQueriesKeepTheirVariables() async throws {
    guard IntegrationEnv.canProxy else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    let client = try await integrationClient("ws://127.0.0.1:\(proxy.port)", websocketOptions: .init(reconnectBaseDelay: 0.05))
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    try await client.set("min", value: .int(5))
    let live = Collected(try await client.live(LiveQuery<Note>(sql: "LIVE SELECT * FROM note WHERE n > $min;")))
    defer { live.cancel() }
    // Changing the variable afterwards doesn't change the running query...
    try await client.set("min", value: .int(100))

    proxy.dropConnections()
    #expect(await eventually { (try? await client.queryRaw("RETURN 1;").first?.result) == .int(1) })

    // ...nor the re-issued one.
    _ = try await client.create(Note(id: nil, text: "ten", n: 10))
    #expect(await eventually { live.snapshot.map(\.decoded?.text) == ["ten"] })
}

/// A live-capable engine whose `query` calls can be made to fail as if the
/// connection dropped again.
private actor FlakyLiveEngine: LiveRPCEngine {
    private var reconnectContinuation: AsyncStream<Void>.Continuation?
    private var streams: [UUID: AsyncStream<LiveWireEvent>.Continuation] = [:]
    private var queryFailures: [any Error] = []
    private(set) var queries = 0
    private(set) var closed: [UUID] = []
    private(set) var moved: [UUID] = []

    func connect() async throws {}
    func close() async {}

    func failNextQuery(with error: any Error) { queryFailures.append(error) }

    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        guard request.method == "query" else {
            return RPCResponseEnvelope(id: request.id, action: nil, result: .null, error: nil)
        }
        queries += 1
        if !queryFailures.isEmpty {
            throw queryFailures.removeFirst()
        }
        let row: SurrealValue = .object(["status": .string("OK"), "time": .string("0ms"), "result": .uuid(UUID())])
        return RPCResponseEnvelope(id: request.id, action: nil, result: .array([row]), error: nil)
    }

    func openLiveStream(for queryID: UUID) async -> AsyncStream<LiveWireEvent> {
        AsyncStream { self.streams[queryID] = $0 }
    }

    func closeLiveStream(for queryID: UUID) async {
        closed.append(queryID)
        streams.removeValue(forKey: queryID)?.finish()
    }

    func moveLiveStream(from oldID: UUID, to newID: UUID) async {
        moved.append(newID)
        streams[newID] = streams.removeValue(forKey: oldID)
    }

    func reconnectEvents() -> AsyncStream<Void> {
        AsyncStream { self.reconnectContinuation = $0 }
    }

    func fireReconnect() { reconnectContinuation?.yield(()) }
    func hasSubscriber() -> Bool { reconnectContinuation != nil }
}

private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("Timed out waiting for a condition")
}

@Test
func core_resubscribeKeepsTheStreamWhenTheConnectionDropsAgain() async throws {
    let engine = FlakyLiveEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()
    try await waitFor { await engine.hasSubscriber() }
    let stream = try await core.live(LiveQuery<SurrealValue>(sql: "LIVE SELECT * FROM note;"), session: nil)
    _ = stream

    // The re-issue fails because the new socket dropped too: keep the stream.
    await engine.failNextQuery(with: SurrealError.connectionLost(cause: nil))
    await engine.fireReconnect()
    try await waitFor { await engine.queries == 2 }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await engine.closed.isEmpty)

    // The next reconnect re-issues it.
    await engine.fireReconnect()
    try await waitFor { await engine.moved.count == 1 }
    #expect(await engine.closed.isEmpty)

    // The server refusing the query does end the stream.
    await engine.failNextQuery(with: SurrealError.queryErrors([QueryErrorDetail(index: 0, message: "no", details: nil)]))
    await engine.fireReconnect()
    try await waitFor { await engine.closed.count == 1 }

    // So does a timeout: the socket may be up, with no reconnect to retry.
    _ = try await core.live(LiveQuery<SurrealValue>(sql: "LIVE SELECT * FROM note;"), session: nil)
    await engine.failNextQuery(with: SurrealError.timeout)
    await engine.fireReconnect()
    try await waitFor { await engine.closed.count == 2 }
}

@Test
func core_liveOfRejectsASecondStreamForTheSameQuery() async throws {
    let engine = FlakyLiveEngine()
    let core = SurrealClientCore(engine: engine)
    try await core.connect()
    let id = UUID()
    _ = try await core.liveOf(id, session: nil, as: SurrealValue.self)
    await #expect(throws: SurrealError.self) {
        _ = try await core.liveOf(id, session: nil, as: SurrealValue.self)
    }
    let live = try await core.live(LiveQuery<SurrealValue>(sql: "LIVE SELECT * FROM note;"), session: nil)
    _ = live
    _ = try await core.liveOf(UUID(), session: nil, as: SurrealValue.self)
}
