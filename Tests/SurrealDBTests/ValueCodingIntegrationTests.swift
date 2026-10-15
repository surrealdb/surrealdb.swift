import Foundation
import Testing
@testable import SurrealDB

private struct Event: SurrealModel, Codable, Sendable, Equatable {
    static let surrealTable = "event"
    var id: SurrealRecordID?
    var owner: SurrealRecordID
    var at: Date
    var token: UUID
    var blob: Data
    var wait: SurrealValue
}

@Test
func integration_typedValuesRoundTripWithoutLoss() async throws {
    guard IntegrationEnv.enabled else { return }

    // Over WS and HTTP with CBOR. (JSON is lossy by design.)
    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        let at = Date(timeIntervalSince1970: -86_400.25) // 1969-12-31T00:00:00.-25: before 1970, with millis
        let original = Event(
            id: nil,
            owner: SurrealRecordID(table: "user", id: .int(42)),
            at: at,
            token: UUID(),
            blob: Data([0, 255]),
            wait: .duration("1h30m")
        )

        let created = try #require(try await client.create(original).first)
        let id = try #require(created.id)
        #expect(id.table == "event")
        #expect(created.owner == original.owner)
        #expect(created.at == at)
        #expect(created.token == original.token)
        #expect(created.blob == original.blob)
        #expect(created.wait == .duration("1h30m"))

        // The server stored real types, not strings.
        let types = try await client.queryRaw(
            "SELECT VALUE [type::is_record(owner), type::is_datetime(at), type::is_uuid(token), type::is_bytes(blob), type::is_duration(wait), at < d'1970-01-01'] FROM type::record($id);",
            bindings: ["id": .recordID(id)]
        )
        #expect(types.first?.result == .array([.array(Array(repeating: .bool(true), count: 6))]))

        let fetched = try await client.select(recordID: id, as: Event.self)
        #expect(fetched == created)
    }
}
