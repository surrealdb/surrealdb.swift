import Foundation
import PotentCBOR
import Testing
@testable import SurrealDB

private struct Watched: SurrealModel, Codable, Sendable {
    static let surrealTable = "watched"
    let id: SurrealRecordID?
    let name: String
}

@Test
func live_decodesKilledNotificationWithoutRecord() throws {
    // KILLED carries no record and no result.
    let queryID = UUID()
    var map = CBOR.Map()
    map[.utf8String("result")] = CBORSurrealCodec.toCBOR(.object([
        "id": .uuid(queryID),
        "action": .string("KILLED"),
        "record": .none,
        "result": .none,
    ]))
    let envelope = try CBORSurrealCodec.decodeRPCEnvelope(try CBORSerialization.data(from: .map(map)))

    let event = try #require(RPCWire.decodeLiveEvent(from: envelope))
    #expect(event.action == .killed)
    #expect(event.queryID == queryID)
    #expect(event.recordID == "")
    #expect(event.record == nil)
}

@Test
func live_decodesRecordFromNotification() throws {
    let record = SurrealRecordID(table: "watched", id: .string("a"))
    let event = try #require(RPCWire.decodeLiveEvent(from: .object([
        "id": .uuid(UUID()),
        "action": .string("CREATE"),
        "record": .recordID(record),
        "result": .object(["id": .recordID(record), "name": .string("x")]),
    ])))
    #expect(event.record == .recordID(record))
    #expect(event.recordID == "watched:a")
}

@Test
func live_topLevelNotificationKeepsItsRecord() throws {
    // A projection like `LIVE SELECT name FROM ...` leaves the payload
    // without an id; the envelope's own record field still has it.
    let queryID = UUID()
    let record = SurrealRecordID(table: "watched", id: .string("a"))
    var map = CBOR.Map()
    map[.utf8String("id")] = .utf8String(queryID.uuidString)
    map[.utf8String("action")] = .utf8String("CREATE")
    map[.utf8String("record")] = CBORSurrealCodec.toCBOR(.recordID(record))
    map[.utf8String("result")] = CBORSurrealCodec.toCBOR(.object(["name": .string("x")]))
    let cbor = try CBORSurrealCodec.decodeRPCEnvelope(try CBORSerialization.data(from: .map(map)))
    let fromCBOR = try #require(RPCWire.decodeLiveEvent(from: cbor))
    #expect(fromCBOR.record == .recordID(record))
    #expect(fromCBOR.recordID == "watched:a")

    let json = #"{"id":"\#(queryID.uuidString)","action":"CREATE","record":"watched:a","result":{"name":"x"}}"#
    let fromJSON = try #require(RPCWire.decodeLiveEvent(from: try JSONRPCCodec.decodeRPCEnvelope(Data(json.utf8))))
    #expect(fromJSON.recordID == "watched:a")
}

@Test
func integration_liveStreamDeliversKilledAndFinishes() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE watched SCHEMALESS;")

    let stream = try await client.live(SurrealDSL.live(Watched.self))
    let collector = Task<[LiveEvent<Watched>], Error> {
        var events: [LiveEvent<Watched>] = []
        for await event in stream {
            events.append(event)
        }
        // Only reached if the stream finishes.
        return events
    }

    _ = try await client.create(Watched(id: nil, name: "one"))
    // Removing the table ends every live query on it with KILLED.
    _ = try await client.queryRaw("REMOVE TABLE watched;")

    let events = try await awaitTaskValue(collector, timeoutSeconds: 10, timeoutMessage: "Live stream never finished after KILLED.")
    #expect(events.first?.action == .create)
    #expect(events.first?.record?.table == "watched")
    #expect(events.first?.decoded?.name == "one")
    #expect(events.last?.action == .killed)
    #expect(events.last?.recordID == "")
}

@Test
func recordID_parsesTheServersTextForm() {
    #expect(SurrealRecordID(parsing: "person:alice") == SurrealRecordID(table: "person", id: .string("alice")))
    #expect(SurrealRecordID(parsing: "person:42") == SurrealRecordID(table: "person", id: .int(42)))
    #expect(SurrealRecordID(parsing: "person:`123`") == SurrealRecordID(table: "person", id: .string("123")))
    #expect(SurrealRecordID(parsing: "person:⟨a b⟩") == SurrealRecordID(table: "person", id: .string("a b")))
    #expect(SurrealRecordID(parsing: "`we:ird`:x") == SurrealRecordID(table: "we:ird", id: .string("x")))
    #expect(SurrealRecordID(parsing: "nocolon") == nil)
    // Typed keys keep their type, or aren't guessed at.
    let uuid = UUID()
    #expect(SurrealRecordID(parsing: "t:u'\(uuid.uuidString.lowercased())'") == SurrealRecordID(table: "t", id: .uuid(uuid)))
    #expect(SurrealRecordID(parsing: "t:[1, 'a']") == nil)
    #expect(SurrealRecordID(parsing: "t:{ a: 1 }") == nil)
    #expect(SurrealRecordID(parsing: "outer:person:alice") == nil)
    #expect(SurrealRecordID(parsing: "t:⟨a:b⟩") == SurrealRecordID(table: "t", id: .string("a:b")))
    // Round-trips what rawValue renders.
    for id in [SurrealRecordID(table: "t", id: .string("a b")), SurrealRecordID(table: "t", id: .int(-5)), SurrealRecordID(table: "t", id: .string("007")), SurrealRecordID(table: "t", id: .uuid(uuid))] {
        #expect(SurrealRecordID(parsing: id.rawValue) == id)
    }
}

@Test
func integration_liveEventRecordOverJSON() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: wsEndpoint(), wireProtocol: .json)
    try await client.connect()
    defer { Task { await client.close() } }
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
    _ = try await client.queryRaw("DEFINE TABLE watched SCHEMALESS;")

    let stream = try await client.live(SurrealDSL.live(Watched.self))
    _ = try await client.queryRaw("CREATE watched:j SET name = 'json';")
    let event = try await awaitTaskValue(Task { () -> LiveEvent<Watched>? in
        for await event in stream { return event }
        return nil
    }, timeoutSeconds: 10, timeoutMessage: "No live event over JSON.")
    #expect(event?.record == SurrealRecordID(table: "watched", id: .string("j")))
}
