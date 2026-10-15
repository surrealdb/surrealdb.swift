import Foundation
import Testing
@testable import SurrealDB

private struct Item: SurrealModel, Codable, Sendable, Equatable {
    static let surrealTable = "item"
    var id: SurrealRecordID?
    var name: String
    var qty: Int

    init(id: SurrealRecordID? = nil, name: String, qty: Int) {
        self.id = id
        self.name = name
        self.qty = qty
    }

    enum Fields {
        static let name = SurrealField<Item, String>("name")
    }
}

private struct Link: SurrealModel, Codable, Sendable {
    static let surrealTable = "link"
    var id: SurrealRecordID?
    var from: SurrealRecordID
    var to: SurrealRecordID
    var weight: Int

    enum CodingKeys: String, CodingKey {
        case id, weight
        case from = "in"
        case to = "out"
    }
}

private func item(_ n: Int64) -> SurrealRecordID {
    SurrealRecordID(table: "item", id: .int(n))
}

@Test
func ranges_fromSwiftRanges() {
    #expect(SurrealRange(1...3) == SurrealRange(begin: .included(.int(1)), end: .included(.int(3))))
    #expect(SurrealRange(1..<3) == SurrealRange(begin: .included(.int(1)), end: .excluded(.int(3))))
    #expect(SurrealRange(2...) == SurrealRange(begin: .included(.int(2)), end: .unbounded))
    #expect(SurrealRange(..<5) == SurrealRange(begin: .unbounded, end: .excluded(.int(5))))
    #expect(SurrealRecordRange(table: "t", range: SurrealRange(1...2)).surrealValue
        == .recordID(SurrealRecordID(table: "t", id: .range(SurrealRange(1...2)))))
}

@Test
func patchOperations_encodeAsJSONPatch() {
    #expect(SurrealPatchOperation.replace(path: "/a", value: .int(1)).surrealValue
        == .object(["op": .string("replace"), "path": .string("/a"), "value": .int(1)]))
    #expect(SurrealPatchOperation.move(from: "/a", path: "/b").surrealValue
        == .object(["op": .string("move"), "from": .string("/a"), "path": .string("/b")]))
}

@Test
func integration_insertMergePatchRelateAndRanges() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        // insert: many in one statement, then one.
        let inserted = try await client.insert((1...4).map { Item(id: item(Int64($0)), name: "i\($0)", qty: $0) })
        #expect(inserted.count == 4)
        let fifth = try await client.insert(Item(id: item(5), name: "i5", qty: 5))
        #expect(fifth?.id == item(5))

        // merge: only the given fields change.
        let merged = try await client.merge(recordID: item(1), with: ["qty": SurrealValue.int(10)], as: Item.self)
        #expect(merged == Item(id: item(1), name: "i1", qty: 10))
        let byPredicate = try await client.merge(Item.self, with: ["qty": SurrealValue.int(0)], where: Item.Fields.name == "i2")
        #expect(byPredicate.map(\.qty) == [0])
        #expect(try await client.select(recordID: item(3), as: Item.self)?.qty == 3)

        // patch: applied as a whole, or not at all.
        let patched = try await client.patch(recordID: item(3), [.replace(path: "/qty", value: .int(33))], as: Item.self)
        #expect(patched?.qty == 33)
        await #expect(throws: SurrealError.self) {
            _ = try await client.patch(recordID: item(3), [
                .replace(path: "/qty", value: .int(99)),
                .test(path: "/name", value: .string("wrong")),
            ], as: Item.self)
        }
        #expect(try await client.select(recordID: item(3), as: Item.self)?.qty == 33)

        // Record ranges.
        let range = SurrealRecordRange(table: "item", range: SurrealRange(2...4))
        #expect(try await client.select(range: range, as: Item.self).map(\.id) == [item(2), item(3), item(4)])
        let bumped = try await client.merge(range: SurrealRecordRange(table: "item", range: SurrealRange(4...)), with: ["flag": true], as: SurrealValue.self)
        #expect(bumped.count == 2)
        let deleted = try await client.delete(range: SurrealRecordRange(table: "item", range: SurrealRange(..<2)), as: Item.self)
        #expect(deleted.map(\.id) == [item(1)])
        #expect(try await client.select(Item.self).count == 4)

        // relate: one edge, then a fan-out.
        let edge = try await client.relate(item(2), "link", item(3), content: .object(["weight": .int(7)]), as: Link.self)
        #expect(edge?.from == item(2))
        #expect(edge?.to == item(3))
        #expect(edge?.weight == 7)
        let fan = try await client.relate([item(2)], "link", [item(4), item(5)], content: .object(["weight": .int(1)]), as: Link.self)
        #expect(Set(fan.map(\.to)) == [item(4), item(5)])

        // insertRelation: edges from values.
        let more = try await client.insertRelation([
            Link(id: nil, from: item(3), to: item(4), weight: 2),
            Link(id: nil, from: item(4), to: item(5), weight: 3),
        ])
        #expect(more.map(\.weight).sorted() == [2, 3])
        let outgoing = try await client.queryRaw("SELECT VALUE ->link->item FROM ONLY $i;", bindings: ["i": .recordID(item(2))]).first?.result
        if case .array(let targets)? = outgoing {
            #expect(targets.count == 3)
        } else {
            Issue.record("Expected an array of linked records, got \(String(describing: outgoing))")
        }
    }
}
