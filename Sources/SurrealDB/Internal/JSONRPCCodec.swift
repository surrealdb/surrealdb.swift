import Foundation

enum JSONRPCCodec {
    private struct WireRequest: Encodable {
        let id: String
        let method: String
        let params: [SurrealValue]?
        let session: String?
        let txn: String?
    }

    private struct WireResponse: Decodable {
        let id: String?
        let action: String?
        let result: SurrealValue?
        let error: RPCErrorObject?
        let record: SurrealValue?
    }

    static func encode(_ request: RPCRequest) throws -> Data {
        let wire = WireRequest(
            id: request.id,
            method: request.method,
            params: request.params,
            session: request.session,
            txn: request.txn
        )
        return try JSONEncoder.surrealDefault.encode(wire)
    }

    static func decodeRPCEnvelope(_ data: Data) throws -> RPCResponseEnvelope {
        let wire: WireResponse
        do {
            wire = try JSONDecoder.surrealDefault.decode(WireResponse.self, from: data)
        } catch {
            throw SurrealError.invalidResponse(
                "Failed to decode RPC envelope from JSON: \(error.localizedDescription)"
            )
        }
        return RPCResponseEnvelope(
            id: wire.id,
            action: wire.action,
            result: wire.result,
            error: wire.error,
            record: wire.record
        )
    }
}
