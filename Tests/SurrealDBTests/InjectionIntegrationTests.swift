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

private struct Nick: SurrealModel, Codable, Sendable {
    static let surrealTable = "nick"
    let id: String?
    let nickname: String?

    var key: String? { id.flatMap { $0.split(separator: ":").last.map(String.init) } }
}

@Test
func integration_noneAndBytesPredicatesMatchOverEveryCodec() async throws {
    guard IntegrationEnv.enabled else { return }

    for wire in [SurrealWireProtocol.cbor, .json] {
        let client = try SurrealClient(endpoint: httpEndpoint(), wireProtocol: wire)
        try await client.connect()
        defer { Task { await client.close() } }
        try await authenticateIfNeeded(client)
        try await client.use(namespace: IntegrationEnv.namespace, database: "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        _ = try await client.queryRaw("CREATE nick:absent; CREATE nick:null SET nickname = NULL, blob = <bytes>'x'; CREATE nick:ff SET blob = encoding::base64::decode('/w==');")

        let absent = try await client.select(Nick.self, where: SurrealField<Nick, String?>("nickname") == nil)
        #expect(Set(absent.compactMap(\.key)) == ["absent", "ff"], "\(wire)")
        let ff = try await client.select(Nick.self, where: SurrealField<Nick, SurrealValue>("blob") == .bytes(Data([0xff])))
        #expect(ff.compactMap(\.key) == ["ff"], "\(wire)")
    }
}
