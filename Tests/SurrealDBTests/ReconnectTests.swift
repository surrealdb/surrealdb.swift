import Foundation
import Testing
@testable import SurrealDB

@Test
func ws_connectToDeadHostThrows() async throws {
    // Nothing listens on port 1. connect() used to "succeed" here.
    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:1",
        websocketOptions: .init(reconnectEnabled: false)
    )
    await #expect(throws: SurrealError.self) {
        try await client.connect()
    }
    await #expect(throws: SurrealError.self) {
        _ = try await client.queryRaw("RETURN 1;")
    }
}

@Test
func ws_backoffDoublesAndCaps() {
    let options = SurrealWebSocketOptions(reconnectBaseDelay: 0.5, reconnectMaxDelay: 3)
    #expect(WebSocketRPCEngine.backoffDelay(attempt: 1, options: options) == 0.5)
    #expect(WebSocketRPCEngine.backoffDelay(attempt: 2, options: options) == 1)
    #expect(WebSocketRPCEngine.backoffDelay(attempt: 3, options: options) == 2)
    #expect(WebSocketRPCEngine.backoffDelay(attempt: 4, options: options) == 3)
    #expect(WebSocketRPCEngine.backoffDelay(attempt: 100, options: options) == 3)
}

private func proxiedClient(
    _ proxy: TCPProxy,
    options: SurrealWebSocketOptions
) async throws -> SurrealClient {
    let client = try SurrealClient(endpoint: "ws://127.0.0.1:\(proxy.port)", websocketOptions: options)
    try await client.connect()
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    return client
}

@Test
func integration_wsReconnectsOnceAfterDrop() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    let client = try await proxiedClient(proxy, options: .init(reconnectBaseDelay: 0.05))
    defer { Task { await client.close() } }
    #expect(proxy.acceptedConnections == 1)

    proxy.dropConnections()

    let recovered = await eventually {
        (try? await client.queryRaw("RETURN 1;").first?.result) == .int(1)
    }
    #expect(recovered)

    // The receive and ping loops both see the drop; only one reconnect may run.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(proxy.acceptedConnections == 2)
}

@Test
func integration_wsReconnectStopsAfterMaxAttempts() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    let client = try await proxiedClient(
        proxy,
        options: .init(maxReconnectAttempts: 3, reconnectBaseDelay: 0.02, reconnectMaxDelay: 0.05)
    )
    defer { Task { await client.close() } }

    proxy.setRejecting(true)
    proxy.dropConnections()

    // One original connection plus exactly three attempts.
    #expect(await eventually(timeout: 5) { proxy.acceptedConnections == 4 })
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(proxy.acceptedConnections == 4)

    await #expect(throws: SurrealError.self) {
        _ = try await client.queryRaw("RETURN 1;")
    }

    // connect() starts over once the host is back.
    proxy.setRejecting(false)
    try await client.connect()
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    #expect(try await client.queryRaw("RETURN 1;").first?.result == .int(1))
}

@Test
func integration_overlappingConnectsShareOneSocket() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    let client = try SurrealClient(endpoint: "ws://127.0.0.1:\(proxy.port)", websocketOptions: .init(reconnectBaseDelay: 0.05))
    defer { Task { await client.close() } }
    async let first: Void = client.connect()
    async let second: Void = client.connect()
    _ = try await (first, second)

    // One socket, not two with one leaked.
    #expect(proxy.acceptedConnections == 1)
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    #expect(try await client.queryRaw("RETURN 1;").first?.result == .int(1))
}

@Test
func integration_connectTimesOutWhenHandshakeIsNeverAnswered() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    // Nothing is forwarded, so the handshake is never answered.
    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(proxy.port)",
        options: .init(requestTimeout: 0.5),
        websocketOptions: .init(reconnectEnabled: false)
    )
    proxy.setStalled(true)
    let started = Date()
    await #expect(throws: SurrealError.self) {
        try await client.connect()
    }
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test
func integration_closeAbandonsAConnectStillInHandshake() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }

    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(proxy.port)",
        options: .init(requestTimeout: 60),
        websocketOptions: .init(reconnectEnabled: false)
    )
    defer { Task { await client.close() } }
    proxy.setStalled(true)
    let first = Task { try await client.connect() }
    try await Task.sleep(nanoseconds: 300_000_000)

    // close() ends the stalled attempt instead of leaving it to time out.
    let started = Date()
    await client.close()
    await #expect(throws: (any Error).self) {
        try await first.value
    }
    #expect(Date().timeIntervalSince(started) < 10)

    // And a later connect() starts afresh rather than joining it.
    proxy.setStalled(false)
    try await client.connect()
    try await authenticateIfNeeded(client)
    #expect(try await client.queryRaw("RETURN 1;").first?.result == .int(1))
}
