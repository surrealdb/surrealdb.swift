import Foundation
import Network
import PotentCBOR
import Testing
@testable import SurrealDB

// cbor.2: offered first over WebSocket, and over HTTP used only once a
// response has come back as v=2, so a 3.x server keeps getting plain cbor.

@Test
func cbor2_mediaTypeMatching() {
    for mediaType in ["application/cbor; v=2", "application/cbor;v=2", "Application/CBOR; V=2", "application/cbor; charset=x; v=2"] {
        #expect(CBORWireCodec.isCBOR2(mediaType: mediaType), "\(mediaType)")
    }
    for mediaType in [nil, "application/cbor", "application/cbor; v=1", "application/cbor; v=20", "application/json; v=2"] {
        #expect(!CBORWireCodec.isCBOR2(mediaType: mediaType), "\(String(describing: mediaType))")
    }
}

@Test
func cbor2_negotiationPicksTheDialect() throws {
    let offering = CBORWireCodec()
    #expect(try #require(offering.negotiated(subprotocol: "cbor.2") as? CBORWireCodec).dialect == .cbor2)
    #expect(try #require(offering.negotiated(subprotocol: "cbor") as? CBORWireCodec).dialect == .cbor)
    #expect(try #require(offering.negotiated(subprotocol: nil) as? CBORWireCodec).dialect == .cbor)
    #expect(try #require(offering.negotiated(httpContentType: "application/cbor; v=2") as? CBORWireCodec).dialect == .cbor2)
    #expect(try #require(offering.negotiated(httpContentType: "application/cbor") as? CBORWireCodec).dialect == .cbor)

    // Not offered, so not taken even if a server answers with it.
    let plain = CBORWireCodec(offersCBOR2: false)
    #expect(try #require(plain.negotiated(subprotocol: "cbor.2") as? CBORWireCodec).dialect == .cbor)
    #expect(try #require(plain.negotiated(httpContentType: "application/cbor; v=2") as? CBORWireCodec).dialect == .cbor)

    let cbor2 = CBORWireCodec(dialect: .cbor2)
    #expect(cbor2.httpContentType == "application/cbor; v=2")
}

@Test
func cbor2_sizedNumbersAreTaggedOnlyOnCBOR2() throws {
    let values: [(SurrealSizedNumber, CBOR.Tag, CBOR)] = [
        (.i8(-128), CBOR.Tag(rawValue: 180), .negativeInt(127)),
        (.u8(255), CBOR.Tag(rawValue: 181), .unsignedInt(255)),
        (.i16(-32768), CBOR.Tag(rawValue: 182), .negativeInt(32767)),
        (.u16(65535), CBOR.Tag(rawValue: 183), .unsignedInt(65535)),
        (.i32(.min), CBOR.Tag(rawValue: 184), .negativeInt(UInt64(Int32.max))),
        (.u32(.max), CBOR.Tag(rawValue: 185), .unsignedInt(UInt64(UInt32.max))),
        (.u64(.max), CBOR.Tag(rawValue: 186), .unsignedInt(.max)),
    ]
    for (number, tag, payload) in values {
        #expect(CBORSurrealCodec.toCBOR(.sized(number), dialect: .cbor2) == .tagged(tag, payload))
        #expect(try CBORSurrealCodec.fromCBOR(.tagged(tag, payload), dialect: .cbor2) == .sized(number))
        // Plain cbor widens on the way out and refuses the tag on the way in.
        #expect(try CBORSurrealCodec.fromCBOR(CBORSurrealCodec.toCBOR(.sized(number), dialect: .cbor)) == number.widened)
        #expect(throws: SurrealError.self) { try CBORSurrealCodec.fromCBOR(.tagged(tag, payload), dialect: .cbor) }
    }
    #expect(SurrealSizedNumber.u64(.max).widened == .decimal("18446744073709551615"))
    #expect(SurrealSizedNumber.u64(5).widened == .int(5))

    let half = SurrealFloat16(1.5)
    #expect(CBORSurrealCodec.toCBOR(.sized(.f16(half)), dialect: .cbor2) == .tagged(CBOR.Tag(rawValue: 187), .half(CBOR.Half(1.5))))
    #expect(CBORSurrealCodec.toCBOR(.sized(.f32(2.5)), dialect: .cbor2) == .tagged(CBOR.Tag(rawValue: 188), .float(2.5)))
    #expect(CBORSurrealCodec.toCBOR(.sized(.f32(2.5)), dialect: .cbor) == .double(2.5))
    // A float tag takes any width that holds the value exactly.
    #expect(try CBORSurrealCodec.fromCBOR(.tagged(CBOR.Tag(rawValue: 188), .double(2.5)), dialect: .cbor2) == .sized(.f32(2.5)))
    #expect(throws: SurrealError.self) { try CBORSurrealCodec.fromCBOR(.tagged(CBOR.Tag(rawValue: 188), .double(0.1)), dialect: .cbor2) }
    #expect(throws: SurrealError.self) { try CBORSurrealCodec.fromCBOR(.tagged(CBOR.Tag(rawValue: 187), .double(65520)), dialect: .cbor2) }
    // Out of range for the kind.
    #expect(throws: SurrealError.self) { try CBORSurrealCodec.fromCBOR(.tagged(CBOR.Tag(rawValue: 181), .unsignedInt(256)), dialect: .cbor2) }
}

@Test
func cbor2_sizedRecordKeysArePlainInts() throws {
    func record(_ key: CBOR) -> CBOR {
        .tagged(CBORSurrealCodec.tagRecordID, .array([.utf8String("t"), key]))
    }
    let u8 = CBOR.tagged(CBOR.Tag(rawValue: 181), .unsignedInt(5))
    #expect(try CBORSurrealCodec.fromCBOR(record(u8), dialect: .cbor2) == .recordID(.init(table: "t", id: .int(5))))
    // A u64 beyond i64 and any float can't be a key.
    #expect(throws: SurrealError.self) {
        try CBORSurrealCodec.fromCBOR(record(.tagged(CBOR.Tag(rawValue: 186), .unsignedInt(.max))), dialect: .cbor2)
    }
    #expect(throws: SurrealError.self) {
        try CBORSurrealCodec.fromCBOR(record(.tagged(CBOR.Tag(rawValue: 188), .float(1.5))), dialect: .cbor2)
    }
    // Inside an array key the width stays.
    #expect(try CBORSurrealCodec.fromCBOR(record(.array([u8])), dialect: .cbor2) == .recordID(.init(table: "t", id: .array([.sized(.u8(5))]))))
}

@Test
func cbor2_float16Rounding() {
    #expect(SurrealFloat16(1.0).bitPattern == 0x3C00)
    #expect(SurrealFloat16(65504).bitPattern == 0x7BFF)
    #expect(SurrealFloat16(65520).bitPattern == 0x7C00)  // rounds up to infinity
    #expect(SurrealFloat16(-.infinity).bitPattern == 0xFC00)
    #expect(SurrealFloat16(.nan).isNaN)
    #expect(SurrealFloat16(-0.0).bitPattern == 0x8000)
    #expect(SurrealFloat16(0x1p-24).bitPattern == 0x0001)  // smallest subnormal
    #expect(SurrealFloat16(0x1p-25).bitPattern == 0x0000)  // a tie, to even
    #expect(SurrealFloat16(1 + 0x1p-11).bitPattern == 0x3C00)  // a tie, to even
    #expect(SurrealFloat16(1 + 0x1p-11 + 0x1p-20).bitPattern == 0x3C01)
    for bits in [UInt16(0x0001), 0x03FF, 0x0400, 0x3555, 0x7BFF, 0xC000] {
        let half = SurrealFloat16(bitPattern: bits)
        #expect(SurrealFloat16(exactly: half.doubleValue) == half)
    }
    #expect(SurrealFloat16(exactly: 0.1) == nil)
    #expect(SurrealSizedNumber.f16(SurrealFloat16(1.5)).sqlLiteral == "1.5f16")
    #expect(SurrealSizedNumber.f32(.nan).sqlLiteral == "<f32>NaN")
    #expect(SurrealSizedNumber.u8(5).sqlLiteral == "5u8")
}

@Test
func cbor2_sizedNumbersDecodeIntoSwiftTypes() throws {
    #expect(try SurrealValue.sized(.u8(200)).decode(UInt8.self) == 200)
    #expect(try SurrealValue.sized(.u8(200)).decode(Int.self) == 200)
    #expect(throws: (any Error).self) { try SurrealValue.sized(.u8(200)).decode(Int8.self) }
    #expect(try SurrealValue.sized(.u64(.max)).decode(UInt64.self) == .max)
    #expect(try SurrealValue.sized(.f32(1.5)).decode(Double.self) == 1.5)
    #expect(try SurrealValue.sized(.f16(SurrealFloat16(2))).decode(Int.self) == 2)
}

// MARK: - WebSocket

/// A WebSocket server that picks `cbor.2` from the client's offer when
/// `speaksCBOR2`, else `cbor`, and answers `query` with the first parameter
/// echoed back. It records what the client offered and whether its requests
/// carried sized-number tags.
private final class NegotiatingServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "negotiating-surreal")
    private let speaksCBOR2: Bool
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private(set) var offered: [String] = []
    private(set) var chosen: String?
    private(set) var sawSizedTag = false

    init(speaksCBOR2: Bool) {
        self.speaksCBOR2 = speaksCBOR2
    }

    func start() async throws {
        let options = NWProtocolWebSocket.Options()
        options.setClientRequestHandler(queue) { [unowned self] subprotocols, _ in
            // Network.framework splits the header on commas but keeps the spaces.
            self.offered = subprotocols.map { $0.trimmingCharacters(in: .whitespaces) }
            let choice = self.speaksCBOR2 && self.offered.contains("cbor.2") ? "cbor.2" : "cbor"
            self.chosen = choice
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: choice)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
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
        let cbor = try CBORSerialization.cbor(from: data)
        if containsSizedTag(cbor) { sawSizedTag = true }
        guard case .map(let request) = cbor, let id = request[.utf8String("id")] else { return Data() }
        var result: CBOR = .null
        switch request[.utf8String("method")] {
        case .utf8String("version")?:
            result = .utf8String(speaksCBOR2 ? "surrealdb-4.0.0" : "surrealdb-3.3.4")
        case .utf8String("query")?:
            guard case .array(let params)? = request[.utf8String("params")], let value = params.dropFirst().first else { break }
            // `RETURN $v` with the binding echoed, as the server would after
            // its own widening on plain cbor.
            var echoed = value
            if case .map(let bindings) = value, let bound = bindings[.utf8String("v")] {
                echoed = chosen == "cbor.2" ? bound : widen(bound)
            }
            var row = CBOR.Map()
            row[.utf8String("status")] = .utf8String("OK")
            row[.utf8String("time")] = .utf8String("0ms")
            row[.utf8String("result")] = echoed
            result = .array([.map(row)])
        default:
            break
        }
        var response = CBOR.Map()
        response[.utf8String("id")] = id
        response[.utf8String("result")] = result
        return try CBORSerialization.data(from: .map(response))
    }

    private func containsSizedTag(_ cbor: CBOR) -> Bool {
        switch cbor {
        case .tagged(let tag, let inner): (180...188).contains(tag.rawValue) || containsSizedTag(inner)
        case .array(let items): items.contains(where: containsSizedTag)
        case .map(let map): map.values.contains(where: containsSizedTag)
        default: false
        }
    }

    private func widen(_ cbor: CBOR) -> CBOR {
        if case .tagged(let tag, let inner) = cbor, (180...188).contains(tag.rawValue) { return inner }
        return cbor
    }
}

@Test
func cbor2_websocketUsesCBOR2WhenTheServerPicksIt() async throws {
    let server = NegotiatingServer(speaksCBOR2: true)
    try await server.start()
    defer { server.stop() }

    let client = try SurrealClient(endpoint: "ws://127.0.0.1:\(server.port)", websocketOptions: .init(reconnectEnabled: false))
    try await client.connect()
    defer { Task { await client.close() } }

    #expect(server.offered == ["cbor.2", "cbor"])
    let rows = try await client.queryRaw("RETURN $v", bindings: ["v": .sized(.u8(5))])
    #expect(rows.first?.result == .sized(.u8(5)))
    #expect(server.sawSizedTag)
}

@Test
func cbor2_websocketFallsBackToCBORWhenTheServerPicksIt() async throws {
    let server = NegotiatingServer(speaksCBOR2: false)
    try await server.start()
    defer { server.stop() }

    let client = try SurrealClient(endpoint: "ws://127.0.0.1:\(server.port)", websocketOptions: .init(reconnectEnabled: false))
    try await client.connect()
    defer { Task { await client.close() } }

    #expect(server.offered == ["cbor.2", "cbor"])
    #expect(server.chosen == "cbor")
    let rows = try await client.queryRaw("RETURN $v", bindings: ["v": .sized(.u8(5))])
    #expect(rows.first?.result == .int(5))
    #expect(!server.sawSizedTag)
}

@Test
func cbor2_websocketOffersOnlyCBORWhenTurnedOff() async throws {
    let server = NegotiatingServer(speaksCBOR2: true)
    try await server.start()
    defer { server.stop() }

    let client = try SurrealClient(
        endpoint: "ws://127.0.0.1:\(server.port)",
        options: .init(negotiatesCBOR2: false),
        websocketOptions: .init(reconnectEnabled: false)
    )
    try await client.connect()
    defer { Task { await client.close() } }

    #expect(server.offered == ["cbor"])
    let rows = try await client.queryRaw("RETURN $v", bindings: ["v": .sized(.u8(5))])
    #expect(rows.first?.result == .int(5))
    #expect(!server.sawSizedTag)
}

// MARK: - HTTP

/// Answers every RPC as a 4.0 server (`v=2` when the request accepts it) or
/// a 3.x one (always plain cbor), and records each request's headers.
private final class NegotiatingHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var speaksCBOR2 = true
    nonisolated(unsafe) static var requests: [(contentType: String?, accept: String?, sawSizedTag: Bool)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
        let accept = request.value(forHTTPHeaderField: "Accept")
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let sawSizedTag = body.contains(0xD8) && (try? CBORSerialization.cbor(from: body)).map(Self.containsSizedTag) == true
        Self.requests.append((contentType, accept, sawSizedTag))

        let replyV2 = Self.speaksCBOR2 && CBORWireCodec.isCBOR2(mediaType: accept)
        var response = CBOR.Map()
        response[.utf8String("id")] = .utf8String("1")
        var row = CBOR.Map()
        row[.utf8String("status")] = .utf8String("OK")
        row[.utf8String("time")] = .utf8String("0ms")
        row[.utf8String("result")] = replyV2 ? .tagged(CBOR.Tag(rawValue: 181), .unsignedInt(5)) : .unsignedInt(5)
        response[.utf8String("result")] = .array([.map(row)])
        let data = (try? CBORSerialization.data(from: .map(response))) ?? Data()

        let headers = ["Content-Type": replyV2 ? "application/cbor; v=2" : "application/cbor"]
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func containsSizedTag(_ cbor: CBOR) -> Bool {
        switch cbor {
        case .tagged(let tag, let inner): (180...188).contains(tag.rawValue) || containsSizedTag(inner)
        case .array(let items): items.contains(where: containsSizedTag)
        case .map(let map): map.values.contains(where: containsSizedTag)
        default: false
        }
    }
}

private func httpEngine(offersCBOR2: Bool = true) async throws -> HTTPRPCEngine {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NegotiatingHTTPStub.self]
    let engine = HTTPRPCEngine(
        endpoint: URL(string: "http://127.0.0.1:1/rpc")!,
        options: SurrealClientOptions(),
        codec: CBORWireCodec(offersCBOR2: offersCBOR2),
        urlSession: URLSession(configuration: configuration)
    )
    try await engine.connect()
    return engine
}

private func sizedQuery() -> RPCRequest {
    RPCRequest(id: "1", method: "query", params: [.string("RETURN $v"), .object(["v": .sized(.u8(5))])], session: nil, txn: nil)
}

/// Serialised: the stub's state is shared.
@Suite(.serialized)
struct CBOR2HTTPNegotiationTests {
    @Test
    func switchesToCBOR2AfterAV2Response() async throws {
        NegotiatingHTTPStub.speaksCBOR2 = true
        NegotiatingHTTPStub.requests = []
        let engine = try await httpEngine()

        let first = try await engine.send(sizedQuery(), session: SessionContext())
        let second = try await engine.send(sizedQuery(), session: SessionContext())

        let requests = NegotiatingHTTPStub.requests
        #expect(requests.count == 2)
        // The first request is plain cbor, asking for v=2...
        #expect(requests[0].contentType == "application/cbor")
        #expect(requests[0].accept == "application/cbor; v=2")
        #expect(!requests[0].sawSizedTag)
        // ...and once the server answered in v=2, requests are v=2 too.
        #expect(requests[1].contentType == "application/cbor; v=2")
        #expect(requests[1].sawSizedTag)
        for envelope in [first, second] {
            #expect(try RPCWire.decodeQueryResults(from: envelope.result ?? .null).first?.result == .sized(.u8(5)))
        }
    }

    @Test
    func staysOnCBORWithA3xServer() async throws {
        NegotiatingHTTPStub.speaksCBOR2 = false
        NegotiatingHTTPStub.requests = []
        let engine = try await httpEngine()

        for _ in 0..<2 {
            let envelope = try await engine.send(sizedQuery(), session: SessionContext())
            #expect(try RPCWire.decodeQueryResults(from: envelope.result ?? .null).first?.result == .int(5))
        }
        for request in NegotiatingHTTPStub.requests {
            #expect(request.contentType == "application/cbor")
            #expect(!request.sawSizedTag)
        }
    }

    @Test
    func asksOnlyForCBORWhenTurnedOff() async throws {
        NegotiatingHTTPStub.speaksCBOR2 = true
        NegotiatingHTTPStub.requests = []
        let engine = try await httpEngine(offersCBOR2: false)

        let envelope = try await engine.send(sizedQuery(), session: SessionContext())
        #expect(try RPCWire.decodeQueryResults(from: envelope.result ?? .null).first?.result == .int(5))
        #expect(NegotiatingHTTPStub.requests.first?.accept == "application/cbor")
        #expect(NegotiatingHTTPStub.requests.first?.contentType == "application/cbor")
    }
}
