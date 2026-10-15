import Foundation
import Testing
@testable import SurrealDB

private func stalledClient(_ scheme: String, proxy: TCPProxy, timeout: TimeInterval) async throws -> SurrealClient {
    let client = try SurrealClient(
        endpoint: "\(scheme)://127.0.0.1:\(proxy.port)",
        options: .init(requestTimeout: timeout, pingInterval: 60),
        websocketOptions: .init(reconnectEnabled: false)
    )
    try await client.connect()
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    return client
}

@Test
func integration_requestsTimeOutWhenTheServerStopsAnswering() async throws {
    guard IntegrationEnv.enabled else { return }

    for scheme in ["ws", "http"] {
        let proxy = TCPProxy(upstream: IntegrationEnv.host)
        try await proxy.start()
        defer { proxy.shutdown() }

        // The timeout also covers connect/signin/use, so leave room for a
        // loaded machine.
        let client = try await stalledClient(scheme, proxy: proxy, timeout: 5)
        defer { Task { await client.close() } }

        proxy.setStalled(true)
        let started = Date()
        // This used to wait forever on WebSocket.
        await #expect {
            _ = try await client.queryRaw("RETURN 1;")
        } throws: { error in
            if case SurrealError.timeout = error { return true }
            return false
        }
        #expect(Date().timeIntervalSince(started) < 20, "\(scheme) took too long to time out")
    }
}

@Test
func integration_cancellingAQueryReturnsPromptly() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    let client = try await stalledClient("ws", proxy: proxy, timeout: 60)
    defer { Task { await client.close() } }

    proxy.setStalled(true)
    let query = Task { try await client.queryRaw("RETURN 1;") }
    try await Task.sleep(nanoseconds: 200_000_000)

    let started = Date()
    query.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await query.value
    }
    #expect(Date().timeIntervalSince(started) < 2)
}

@Test
func integration_wsConnectTimesOutAgainstASilentHost() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    proxy.setStalled(true)

    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(proxy.port)",
        options: .init(requestTimeout: 0.5),
        websocketOptions: .init(reconnectEnabled: false)
    )
    let started = Date()
    await #expect(throws: SurrealError.self) {
        try await client.connect()
    }
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test
func integration_aTimedOutStateChangeResetsTheSocket() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(proxy.port)",
        options: .init(requestTimeout: 5, pingInterval: 60),
        websocketOptions: .init(reconnectBaseDelay: 0.05)
    )
    try await client.connect()
    defer { Task { await client.close() } }
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    let before = proxy.acceptedConnections

    // A timed-out query leaves the socket alone...
    proxy.setStalled(true)
    await #expect(throws: SurrealError.self) { _ = try await client.queryRaw("RETURN 1;") }
    #expect(proxy.acceptedConnections == before)

    // ...but a timed-out `use` might still be applied, so the client starts
    // over on a new socket and replays the state it knows.
    await #expect(throws: SurrealError.self) {
        try await client.use(namespace: IntegrationEnv.namespace, database: "elsewhere")
    }
    proxy.setStalled(false)
    #expect(await eventually { proxy.acceptedConnections > before })
    #expect(await eventually {
        (try? await client.queryRaw("RETURN session::db();").first?.result) == .string(IntegrationEnv.database)
    })
}

@Test
func integration_aCancelledStateChangeResetsTheSocket() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(proxy.port)",
        options: .init(requestTimeout: 60, pingInterval: 60),
        websocketOptions: .init(reconnectBaseDelay: 0.05)
    )
    try await client.connect()
    defer { Task { await client.close() } }
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    let before = proxy.acceptedConnections

    // A `use` cancelled before its reply might still be applied, so the
    // client starts over on a new socket and replays the state it knows.
    proxy.setStalled(true)
    let use = Task { try await client.use(namespace: IntegrationEnv.namespace, database: "elsewhere") }
    try await Task.sleep(nanoseconds: 200_000_000)
    use.cancel()
    await #expect(throws: CancellationError.self) { try await use.value }
    proxy.setStalled(false)
    #expect(await eventually { proxy.acceptedConnections > before })
    #expect(await eventually {
        (try? await client.queryRaw("RETURN session::db();").first?.result) == .string(IntegrationEnv.database)
    })
}
