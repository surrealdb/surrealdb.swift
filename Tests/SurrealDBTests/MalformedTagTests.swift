import Foundation
import Network
import PotentCBOR
import Testing
@testable import SurrealDB

private func decode(_ cbor: CBOR) throws -> SurrealValue {
    try CBORSurrealCodec.fromCBOR(cbor)
}

@Test
func malformedTags_invalidStringUUIDThrowsInsteadOfRandom() throws {
    let tag = CBORSurrealCodec.tagStringUUID
    // This used to decode to a brand-new random UUID.
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .utf8String("not-a-uuid"))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .unsignedInt(1))) }
    // Servers send UUIDs in tag 37, and 4.0 refuses the text form even when
    // it's valid.
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .utf8String(UUID().uuidString.lowercased()))) }
}

@Test
func malformedTags_otherTagsThrowInsteadOfInventingValues() {
    #expect(throws: SurrealError.self) { try decode(.tagged(.uuid, .byteString(Data([1, 2, 3])))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagTable, .unsignedInt(1))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagRecordID, .unsignedInt(1))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagStringDecimal, .utf8String("1; x"))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagRange, .null)) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagSet, .null)) }
}

@Test
func malformedTags_surfaceThroughTheEnvelope() throws {
    // A malformed value inside a result used to read as a missing result.
    var map = CBOR.Map()
    map[.utf8String("id")] = .utf8String("1")
    map[.utf8String("result")] = .tagged(CBORSurrealCodec.tagStringUUID, .utf8String("nope"))
    let data = try CBORSerialization.data(from: .map(map))
    #expect(throws: SurrealError.self) { try CBORSurrealCodec.decodeRPCEnvelope(data) }
}

/// A minimal CBOR WebSocket server: answers `version`, and every other
/// request with `null` except `query`, which gets one row, or a malformed UUID tag when the
/// SQL is `BAD`.
private final class FakeSurreal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-surreal")
    private var listener: NWListener?
    private(set) var connections = 0
    private(set) var port: UInt16 = 0

    func start() async throws {
        let options = NWProtocolWebSocket.Options()
        options.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: "cbor")
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections += 1
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield(listener.port?.rawValue ?? 0) }
        }
        listener.start(queue: queue)
        self.listener = listener
        for await port in ready.stream {
            self.port = port
            break
        }
    }

    func stop() { listener?.cancel() }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let reply = try? self.reply(to: data) {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "reply", metadata: [metadata])
                connection.send(content: reply, contentContext: context, completion: .idempotent)
            }
            self.receive(on: connection)
        }
    }

    private func reply(to data: Data) throws -> Data {
        guard case .map(let request) = try CBORSerialization.cbor(from: data),
              let id = request[.utf8String("id")]
        else { return Data() }
        if case .array(let params)? = request[.utf8String("params")], params.first == .utf8String("GARBAGE") {
            // Not even an envelope, so there's no id to match.
            return try CBORSerialization.data(from: .array([.unsignedInt(1)]))
        }
        var result: CBOR = .null
        if request[.utf8String("method")] == .utf8String("version") {
            result = .utf8String("surrealdb-3.3.4")
        } else if request[.utf8String("method")] == .utf8String("query"),
           case .array(let params)? = request[.utf8String("params")] {
            if params.first == .utf8String("BAD") {
                result = .tagged(.uuid, .byteString(Data([1, 2, 3])))
            } else {
                var row = CBOR.Map()
                row[.utf8String("status")] = .utf8String("OK")
                row[.utf8String("time")] = .utf8String("0ms")
                row[.utf8String("result")] = .unsignedInt(1)
                result = .array([.map(row)])
            }
        }
        var response = CBOR.Map()
        response[.utf8String("id")] = id
        response[.utf8String("result")] = result
        return try CBORSerialization.data(from: .map(response))
    }
}

@Test
func malformedTags_aBadReplyFailsOnlyItsRequest() async throws {
    let server = FakeSurreal()
    try await server.start()
    defer { server.stop() }

    let client = try SurrealClient(endpoint: "ws://127.0.0.1:\(server.port)", websocketOptions: .init(reconnectEnabled: false))
    try await client.connect()
    defer { Task { await client.close() } }

    await #expect(throws: SurrealError.self) {
        _ = try await client.queryRaw("BAD", bindings: [:])
    }
    // Same connection, still working.
    let rows = try await client.queryRaw("GOOD", bindings: [:])
    #expect(rows.first?.result == .int(1))
    #expect(server.connections == 1)
}

@Test
func malformedTags_anUnmatchableReplyResetsTheConnection() async throws {
    let server = FakeSurreal()
    try await server.start()
    defer { server.stop() }

    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(server.port)",
        options: .init(requestTimeout: 30),
        websocketOptions: .init(reconnectBaseDelay: 0.05)
    )
    try await client.connect()
    defer { Task { await client.close() } }

    // Fails now, rather than at the timeout...
    let started = Date()
    await #expect(throws: SurrealError.self) {
        _ = try await client.queryRaw("GARBAGE", bindings: [:])
    }
    #expect(Date().timeIntervalSince(started) < 5)
    // ...and the client carries on over a new connection.
    #expect(await eventually { (try? await client.queryRaw("GOOD", bindings: [:]).first?.result) == .int(1) })
    #expect(server.connections == 2)
}
