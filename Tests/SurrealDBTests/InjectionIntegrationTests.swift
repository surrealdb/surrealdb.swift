import Foundation
import Testing
@testable import SurrealDB

private struct Victim: SurrealModel, Codable, Sendable {
    static let surrealTable = "victim"
    let id: String?
    let name: String
}

private struct OddTable: SurrealModel, Codable, Sendable {
    static let surrealTable = "odd`ta\\ble"
    let id: String?
    let name: String
}

@Test
func integration_hostileValuesAndIdsCannotInject() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        _ = try await client.create(Victim(id: nil, name: "keep me"))

        // A value ending in a backslash used to escape the closing quote.
        let hostileName = #"x\"; DELETE victim; --\"#
        let matched = try await client.select(Victim.self, where: SurrealField<Victim, String>("name") == hostileName)
        #expect(matched.isEmpty)

        // Record ids used to be spliced into the statement text.
        let hostileID = SurrealRecordID(table: "victim", id: .string("a`; DELETE victim; --"))
        let created = try await client.create(recordID: hostileID, content: Victim(id: nil, name: hostileName))
        #expect(created?.name == hostileName)
        let fetched = try await client.select(recordID: hostileID, as: Victim.self)
        #expect(fetched?.name == hostileName)
        _ = try await client.delete(recordID: hostileID, as: Victim.self)

        let survivors = try await client.select(Victim.self)
        #expect(survivors.map(\.name) == ["keep me"])

        // Table names are escaped too.
        _ = try await client.create(OddTable(id: nil, name: "odd"))
        let odd = try await client.select(OddTable.self, where: SurrealField<OddTable, String>("name") == "odd")
        #expect(odd.count == 1)
    }
}
