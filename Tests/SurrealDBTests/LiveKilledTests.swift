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
