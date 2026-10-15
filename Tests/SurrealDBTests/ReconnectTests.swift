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
