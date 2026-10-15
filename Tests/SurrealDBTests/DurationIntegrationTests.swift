import Foundation
import Testing
@testable import SurrealDB

@Test
func integration_durationsRoundTripThroughServer() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        // Durations used to come back as "".
        let rows = try await client.queryRaw("RETURN [1h30m, 1s500ms, 0ns, 400d, 1ns];")
        #expect(rows.first?.result == .array([
            .duration("1h30m"), .duration("1s500ms"), .duration("0ns"), .duration("1y5w"), .duration("1ns"),
        ]))

        // A bound duration reaches the server as a duration, not a string.
        let echoed = try await client.queryRaw(
            "RETURN [type::is_duration($d), $d + 30m];",
            bindings: ["d": .duration("1h30m")]
        )
        #expect(echoed.first?.result == .array([.bool(true), .duration("2h")]))
    }
}
