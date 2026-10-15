import Foundation
import PotentCBOR

/// Selects the wire encoding used by an engine when serializing RPC traffic.
public enum SurrealWireProtocol: Sendable, Hashable {
    /// SurrealDB's tagged CBOR encoding. Preserves all `SurrealValue` types
    /// (UUID, datetime, record IDs, geometries, ranges, etc.) without lossy
    /// coercion. Default.
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
    /// WebSocket sub-protocols proposed during the WS handshake.
    var websocketSubprotocols: [String] { get }

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

struct CBORWireCodec: WireCodec {
    let httpContentType = "application/cbor"
    let websocketSubprotocols = ["cbor"]

    func encode(_ request: RPCRequest) throws -> Data {
        try CBORSurrealCodec.encode(request)
    }

    func decodeEnvelope(_ data: Data) throws -> RPCResponseEnvelope {
        try CBORSurrealCodec.decodeRPCEnvelope(data)
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
    let websocketSubprotocols = ["json"]

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

func makeWireCodec(_ kind: SurrealWireProtocol) -> any WireCodec {
    switch kind {
    case .cbor:
        return CBORWireCodec()
    case .json:
        return JSONWireCodec()
    }
}
