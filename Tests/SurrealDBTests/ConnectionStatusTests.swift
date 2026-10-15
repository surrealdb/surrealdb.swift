import Foundation
import Testing
@testable import SurrealDB

/// Records a status stream so a test can wait for a sequence.
private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SurrealConnectionStatus] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<SurrealConnectionStatus>) {
        task = Task {
            for await status in stream {
                self.append(status)
            }
        }
    }

    private func append(_ status: SurrealConnectionStatus) {
        lock.lock()
        values.append(status)
        lock.unlock()
    }

    var all: [SurrealConnectionStatus] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func cancel() {
        task?.cancel()
    }
}

@Test
func connectionStatus_startsWithCurrentAndSkipsRepeats() async throws {
    let broadcaster = ConnectionStatusBroadcaster()
    broadcaster.send(.connecting)
    let log = StatusLog(broadcaster.updates())
    defer { log.cancel() }
    broadcaster.send(.connecting)
    broadcaster.send(.connected)
    broadcaster.send(.connected)
    broadcaster.send(.reconnecting(attempt: 1))
    #expect(await eventually { log.all == [.connecting, .connected, .reconnecting(attempt: 1)] })
    #expect(broadcaster.current == .reconnecting(attempt: 1))
}

@Test
func connectionStatus_failedConnectEndsDisconnected() async throws {
    for endpoint in ["ws://127.0.0.1:1", "http://127.0.0.1:1"] {
        let client = try SurrealClient(endpoint: endpoint, websocketOptions: .init(reconnectEnabled: false))
        #expect(client.connectionStatus == .disconnected)
        let log = StatusLog(client.connectionStatusUpdates())
        defer { log.cancel() }
        await #expect(throws: SurrealError.self) {
            try await client.connect()
        }
        #expect(await eventually { log.all == [.disconnected, .connecting, .disconnected] }, "\(endpoint): \(log.all)")
    }
}

@Test
func integration_connectionStatusFollowsReconnects() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(proxy.port)",
        websocketOptions: .init(maxReconnectAttempts: 2, reconnectBaseDelay: 0.05, reconnectMaxDelay: 0.05)
    )
    let log = StatusLog(client.connectionStatusUpdates())
    defer { log.cancel() }

    try await client.connect()
    #expect(client.connectionStatus == .connected)

    // A drop, then a successful reconnect.
    proxy.dropConnections()
    #expect(await eventually { log.all.last == .connected && log.all.count >= 5 }, "\(log.all)")
    #expect(log.all == [.disconnected, .connecting, .connected, .reconnecting(attempt: 1), .connected])

    // A drop that never recovers: both attempts, then disconnected.
    proxy.setRejecting(true)
    proxy.dropConnections()
    #expect(await eventually(timeout: 5) { log.all.last == .disconnected }, "\(log.all)")
    #expect(Array(log.all.suffix(3)) == [.reconnecting(attempt: 1), .reconnecting(attempt: 2), .disconnected])

    // connect() starts over; close() ends disconnected.
    proxy.setRejecting(false)
    try await client.connect()
    #expect(client.connectionStatus == .connected)
    await client.close()
    #expect(client.connectionStatus == .disconnected)
    #expect(await eventually { Array(log.all.suffix(3)) == [.connecting, .connected, .disconnected] }, "\(log.all)")
}

/// A live engine that can park the reconnect replay's `use` call.
private actor HeldReplayEngine: LiveRPCEngine {
    private var reconnectContinuation: AsyncStream<Void>.Continuation?
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var uses = 0
    private var identity: Int? = 1

    func connectionIdentity() async -> Int? { identity }
    /// The socket dropped: no connection until the next reconnect.
    func drop() { identity = nil }

    func connect() async throws {}
    func close() async {}

    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        if request.method == "use" {
            uses += 1
            if holding {
                await withCheckedContinuation { held.append($0) }
            }
        }
        return RPCResponseEnvelope(id: request.id, action: nil, result: .null, error: nil)
    }

    func hold() { holding = true }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }

    func openLiveStream(for queryID: UUID) async -> AsyncStream<LiveWireEvent> { AsyncStream { $0.finish() } }
    func closeLiveStream(for queryID: UUID) async {}
    func moveLiveStream(from oldID: UUID, to newID: UUID) async {}
    func reconnectEvents() -> AsyncStream<Void> { AsyncStream { self.reconnectContinuation = $0 } }
    func fireReconnect() { reconnectContinuation?.yield(()) }
    func hasSubscriber() -> Bool { reconnectContinuation != nil }
}

@Test
func connectionStatus_closeDuringReplayStaysDisconnected() async throws {
    let engine = HeldReplayEngine()
    let status = ConnectionStatusBroadcaster()
    let core = SurrealClientCore(engine: engine, sessionContext: SessionContext(namespace: "ns", database: "db"), status: status)
    try await core.connect()
    #expect(await eventually { await engine.hasSubscriber() })

    await engine.hold()
    await engine.fireReconnect()
    #expect(await eventually { await engine.uses >= 1 })

    await core.close()
    #expect(status.current == .disconnected)
    await engine.release()
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(status.current == .disconnected)
}

@Test
func connectionStatus_replayAfterAnotherDropDoesNotReportConnected() async throws {
    let engine = HeldReplayEngine()
    let status = ConnectionStatusBroadcaster()
    let core = SurrealClientCore(engine: engine, sessionContext: SessionContext(namespace: "ns", database: "db"), status: status)
    try await core.connect()
    defer { Task { await core.close() } }
    #expect(await eventually { await engine.hasSubscriber() })

    await engine.hold()
    await engine.fireReconnect()
    #expect(await eventually { await engine.uses >= 1 })

    // The new socket drops while the replay is still running.
    await engine.drop()
    status.send(.reconnecting(attempt: 1))
    await engine.release()
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(status.current == .reconnecting(attempt: 1))
}
