import Foundation
import Testing
@testable import SurrealDB

private struct Member: SurrealModel, Codable, Sendable {
    static let surrealTable = "member"
    var id: SurrealRecordID?
    var name: String
    var role: String

    init(id: SurrealRecordID? = nil, name: String, role: String) {
        self.id = id
        self.name = name
        self.role = role
    }

    enum Fields {
        static let name = SurrealField<Member, String>("name")
    }
}

@Test
func integration_updateTouchesOnlyMatchingRecords() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        _ = try await client.create(Member(name: "ada", role: "admin"))
        _ = try await client.create(Member(name: "bob", role: "user"))

        // `where` is required now; `update(Member.self, content:)` no longer
        // compiles, so it can't silently replace the whole table.
        let updated = try await client.update(
            Member.self,
            content: Member(name: "ada", role: "owner"),
            where: Member.Fields.name == "ada"
        )
        #expect(updated.map(\.role) == ["owner"])
        let bob = try await client.select(Member.self, where: Member.Fields.name == "bob")
        #expect(bob.map(\.role) == ["user"])

        let upserted = try await client.upsert(
            Member.self,
            content: Member(name: "bob", role: "admin"),
            where: Member.Fields.name == "bob"
        )
        #expect(upserted.map(\.role) == ["admin"])

        // The table-wide form is still there, under a name that says so.
        let all = try await client.updateAll(Member.self, content: Member(name: "x", role: "guest"))
        #expect(all.count == 2)
        #expect(Set(try await client.select(Member.self).map(\.role)) == ["guest"])

        // upsertAll updates every record too, rather than inserting one.
        let upsertedAll = try await client.upsertAll(Member.self, content: Member(name: "y", role: "owner"))
        #expect(upsertedAll.count == 2)
        let after = try await client.select(Member.self)
        #expect(after.count == 2)
        #expect(Set(after.map(\.role)) == ["owner"])
    }
}
