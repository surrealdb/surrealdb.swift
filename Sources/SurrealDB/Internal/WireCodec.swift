import Foundation
import PotentCBOR

/// Selects the wire encoding used by an engine when serializing RPC traffic.
public enum SurrealWireProtocol: Sendable, Hashable {
    /// SurrealDB's tagged CBOR encoding. Preserves all `SurrealValue` types
    /// (UUID, datetime, record IDs, geometries, ranges, etc.) without lossy
    /// coercion. Default. With a SurrealDB 4.0 server this negotiates
    /// `cbor.2`, which also keeps sized numbers (`u8`, `f32`, ...); see
    /// ``SurrealClientOptions/negotiatesCBOR2``.
    case cbor
    /// JSON encoding. Compatible with any HTTP front-end; lossy for
    /// SurrealDB-specific types that don't have a JSON primitive (UUID,
    /// datetime, decimal, duration, record IDs, geometries are sent as
    /// strings/objects).
    case json
}

/// Pluggable wire codec. Two implementations ship today (`CBORWireCodec`,
/// `JSONWireCodec`); additional codecs can be added without touching the
/// engine implementations.
protocol WireCodec: Sendable {
    /// Content-type used for HTTP requests.
    var httpContentType: String { get }
    /// The `Accept` header for HTTP requests: what this codec can read, which
    /// may be more than it sends.
    var httpAccept: String { get }
    /// WebSocket sub-protocols proposed during the WS handshake, preferred
    /// first.
    var websocketSubprotocols: [String] { get }

    /// The codec for the sub-protocol the server chose (`nil` if it named
    /// none).
    func negotiated(subprotocol: String?) -> any WireCodec
    /// The codec for an HTTP response with this `Content-Type`.
    func negotiated(httpContentType: String?) -> any WireCodec

    func encode(_ request: RPCRequest) throws -> Data
    func decodeEnvelope(_ data: Data) throws -> RPCResponseEnvelope
    /// The `id` of a message `decodeEnvelope` couldn't read, if it can be
    /// found without decoding the rest.
    func requestID(in data: Data) -> String?
}

extension WireCodec {
    /// Decodes the result of a `query` RPC method invocation into a list of
    /// per-statement results. Protocol-agnostic because it operates on
    /// `SurrealValue` (already decoded by the wire codec).
    func decodeQueryResults(from value: SurrealValue) throws -> [RPCQueryResult] {
        try RPCWire.decodeQueryResults(from: value)
    }

    /// Decodes a live-query notification envelope.
    func decodeLiveEvent(from envelope: RPCResponseEnvelope) -> LiveWireEvent? {
        RPCWire.decodeLiveEvent(from: envelope)
    }
}

/// CBOR in one of its two dialects. A 4.0 server speaks `cbor.2` as well as
/// plain `cbor`; older servers speak only `cbor`. So a client offers both and
/// speaks what the server picks:
///
/// - WebSocket: offers the sub-protocols `cbor.2` then `cbor`, and a 3.x
///   server picks `cbor`.
/// - HTTP: always accepts `application/cbor; v=2`, but sends
///   `application/cbor` until a response comes back as `v=2`. (A 4.0 server
///   refuses a `v=2` body with 415 when the client accepts only v1, and an
///   older one doesn't know `v=2` at all.)
struct CBORWireCodec: WireCodec {
    /// Where negotiation starts, or the only dialect if `cbor.2` is off.
    let dialect: CBORDialect
    /// Whether to offer `cbor.2` at all.
    let offersCBOR2: Bool

    init(dialect: CBORDialect = .cbor, offersCBOR2: Bool = true) {
        self.dialect = dialect
        self.offersCBOR2 = offersCBOR2
    }

    static let cbor2Subprotocol = "cbor.2"
    static let cbor2MediaType = "application/cbor; v=2"

    var httpContentType: String {
        dialect == .cbor2 ? Self.cbor2MediaType : "application/cbor"
    }

    var httpAccept: String {
        offersCBOR2 ? Self.cbor2MediaType : "application/cbor"
    }

    var websocketSubprotocols: [String] {
        offersCBOR2 ? [Self.cbor2Subprotocol, "cbor"] : ["cbor"]
    }

    func negotiated(subprotocol: String?) -> any WireCodec {
        let chosen: CBORDialect = offersCBOR2 && subprotocol == Self.cbor2Subprotocol ? .cbor2 : .cbor
        return CBORWireCodec(dialect: chosen, offersCBOR2: offersCBOR2)
    }

    func negotiated(httpContentType: String?) -> any WireCodec {
        let chosen: CBORDialect = offersCBOR2 && Self.isCBOR2(mediaType: httpContentType) ? .cbor2 : .cbor
        return CBORWireCodec(dialect: chosen, offersCBOR2: offersCBOR2)
    }

    /// `application/cbor` with a `v=2` parameter, in any spacing or case.
    static func isCBOR2(mediaType: String?) -> Bool {
        guard let mediaType else { return false }
        let parts = mediaType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.first == "application/cbor" else { return false }
        return parts.dropFirst().contains { $0.replacingOccurrences(of: " ", with: "") == "v=2" }
    }

    func encode(_ request: RPCRequest) throws -> Data {
        try CBORSurrealCodec.encode(request, dialect: dialect)
    }

    func decodeEnvelope(_ data: Data) throws -> RPCResponseEnvelope {
        try CBORSurrealCodec.decodeRPCEnvelope(data, dialect: dialect)
    }

    func requestID(in data: Data) -> String? {
        guard case .map(let map)? = try? CBORSerialization.cbor(from: data),
              case .utf8String(let id)? = map[.utf8String("id")]
        else {
            return nil
        }
        return id
    }
}

struct JSONWireCodec: WireCodec {
    let httpContentType = "application/json"
    let httpAccept = "application/json"
    let websocketSubprotocols = ["json"]

    func negotiated(subprotocol: String?) -> any WireCodec { self }
    func negotiated(httpContentType: String?) -> any WireCodec { self }

    func encode(_ request: RPCRequest) throws -> Data {
        try JSONRPCCodec.encode(request)
    }

    func decodeEnvelope(_ data: Data) throws -> RPCResponseEnvelope {
        try JSONRPCCodec.decodeRPCEnvelope(data)
    }

    func requestID(in data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["id"] as? String
    }
}

func makeWireCodec(_ kind: SurrealWireProtocol, offersCBOR2: Bool = true) -> any WireCodec {
    switch kind {
    case .cbor:
        return CBORWireCodec(offersCBOR2: offersCBOR2)
    case .json:
        return JSONWireCodec()
    }
}
