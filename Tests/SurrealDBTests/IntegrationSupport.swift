import Foundation
@testable import SurrealDB

/// Opens a signed-in client on a fresh database, so tests that write data
/// can't see each other's records.
func integrationClient(
    _ endpoint: String,
    options: SurrealClientOptions = .init(),
    websocketOptions: SurrealWebSocketOptions = .init()
) async throws -> SurrealClient {
    let client = try SurrealClient(endpoint: endpoint, options: options, websocketOptions: websocketOptions)
    try await client.connect()
    try await authenticateIfNeeded(client)
    let database = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    try await client.use(namespace: IntegrationEnv.namespace, database: database)
    return client
}

/// Both transports, for tests that should behave the same on each.
var integrationEndpoints: [String] { [wsEndpoint(), httpEndpoint()] }
