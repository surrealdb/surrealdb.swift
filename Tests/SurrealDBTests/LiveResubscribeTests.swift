import Foundation
import Testing
@testable import SurrealDB

private struct Note: SurrealModel, Codable, Sendable, Equatable {
    static let surrealTable = "note"
    var id: SurrealRecordID?
    var text: String
    var n: Int
}

/// Collects a live stream's events so a test can wait for them.
private final class Collected<T: Decodable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveEvent<T>] = []
    private var finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LiveEvent<T>>) {
        task = Task {
            for await event in stream {
                self.append(event)
            }
            self.finish()
        }
    }

    private func append(_ event: LiveEvent<T>) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var snapshot: [LiveEvent<T>] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func cancel() {
        task?.cancel()
    }
}

@Test
func patchOperation_decodesFromDiffs() throws {
    let ops = try SurrealValue.array([
        .object(["op": .string("replace"), "path": .string("/n"), "value": .int(2)]),
        .object(["op": .string("change"), "path": .string("/text"), "value": .string("@@ -1 +1 @@\n-a\n+b\n")]),
        .object(["op": .string("remove"), "path": .string("/old")]),
        .object(["op": .string("move"), "from": .string("/a"), "path": .string("/b")]),
    ]).decode([SurrealPatchOperation].self)
    #expect(ops == [
        .replace(path: "/n", value: .int(2)),
        .change(path: "/text", value: "@@ -1 +1 @@\n-a\n+b\n"),
        .remove(path: "/old"),
        .move(from: "/a", path: "/b"),
    ])
    #expect(throws: (any Error).self) {
        _ = try SurrealValue.object(["op": .string("frobnicate"), "path": .string("/")]).decode(SurrealPatchOperation.self)
    }
}

@Test
func integration_liveOfDeliversNotificationsSentBeforeAttaching() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    // Started with raw SurrealQL: nothing is listening yet when the
    // notifications arrive.
    guard case .uuid(let queryID)? = try await client.queryRaw("LIVE SELECT * FROM note;").first?.result else {
        Issue.record("Expected a live query id")
        return
    }
    _ = try await client.create(Note(id: nil, text: "early", n: 1))
    _ = try await client.queryRaw("RETURN 1;")  // let the notification arrive

    let collected = Collected(try await client.liveOf(queryID, as: Note.self))
    defer { collected.cancel() }
    _ = try await client.create(Note(id: nil, text: "late", n: 2))

    #expect(await eventually { collected.snapshot.count == 2 })
    #expect(collected.snapshot.map { $0.decoded?.text } == ["early", "late"])
    #expect(collected.snapshot.allSatisfy { $0.queryID == queryID })
}

@Test
func integration_liveQueriesResubscribeAfterReconnect() async throws {
    guard IntegrationEnv.enabled else { return }

    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    let client = try await integrationClient("ws://127.0.0.1:\(proxy.port)", websocketOptions: .init(reconnectBaseDelay: 0.05))
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    let live = Collected(try await client.live(SurrealDSL.live(Note.self, where: SurrealField<Note, Int>("n") > 0)))
    defer { live.cancel() }
    guard case .uuid(let rawID)? = try await client.queryRaw("LIVE SELECT * FROM note;").first?.result else {
        Issue.record("Expected a live query id")
        return
    }
    let attached = Collected(try await client.liveOf(rawID, as: Note.self))
    defer { attached.cancel() }

    _ = try await client.create(Note(id: nil, text: "before", n: 1))
    #expect(await eventually { live.snapshot.count == 1 && attached.snapshot.count == 1 })
    let firstID = try #require(live.snapshot.first?.queryID)

    proxy.dropConnections()
    let recovered = await eventually {
        (try? await client.queryRaw("RETURN 1;").first?.result) == .int(1)
    }
    #expect(recovered)

    // The same stream carries on, under the re-issued query's new id, with
    // its predicate (and its bindings) intact.
    _ = try await client.create(Note(id: nil, text: "skipped", n: 0))
    _ = try await client.create(Note(id: nil, text: "after", n: 2))
    #expect(await eventually { live.snapshot.count == 2 })
    #expect(live.snapshot.map { $0.decoded?.text } == ["before", "after"])
    #expect(live.snapshot.last?.queryID != firstID)
    #expect(!live.isFinished)

    // A stream attached with liveOf can't be re-issued, so it finished.
    #expect(await eventually { attached.isFinished })
    #expect(attached.snapshot.count == 1)

    // Ending the stream kills the re-issued query on the server.
    live.cancel()
    let newID = try #require(live.snapshot.last?.queryID)
    #expect(await eventually {
        do {
            try await client.kill(liveQueryID: newID)
            return false
        } catch {
            return true
        }
    })
}

@Test
func integration_liveDiffSendsPatchOperations() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }
    _ = try await client.queryRaw("DEFINE TABLE note SCHEMALESS;")

    let collected = Collected(try await client.live(SurrealDSL.liveDiff(Note.self)))
    defer { collected.cancel() }

    let id = SurrealRecordID(table: "note", id: .string("d"))
    _ = try await client.create(recordID: id, content: Note(id: nil, text: "hello world", n: 1))
    _ = try await client.merge(recordID: id, with: ["text": SurrealValue.string("hello there world"), "n": .int(2)], as: Note.self)

    #expect(await eventually { collected.snapshot.count == 2 })
    let events = collected.snapshot
    #expect(events.map(\.action) == [.create, .update])
    #expect(events.first?.record == id)
    let changes = try #require(events.last?.decoded)
    #expect(changes.contains(.replace(path: "/n", value: .int(2))))
    #expect(changes.contains { if case .change(path: "/text", _) = $0 { return true } else { return false } })
}
