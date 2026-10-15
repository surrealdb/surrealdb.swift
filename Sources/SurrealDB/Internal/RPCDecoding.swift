import Foundation

/// Wire-protocol-neutral decoders. These operate on already-decoded
/// `SurrealValue` / `RPCResponseEnvelope` so they're identical regardless of
/// whether the bytes came from CBOR or JSON.
enum RPCWire {
    static func decodeQueryResults(from value: SurrealValue) throws -> [RPCQueryResult] {
        guard case .array(let rows) = value else {
            throw SurrealError.invalidResponse("Expected query result array.")
        }

        return try rows.enumerated().map { index, value in
            guard case .object(let object) = value else {
                throw SurrealError.invalidResponse("Expected query result object at index \(index).")
            }

            guard
                let statusRaw = object["status"],
                case .string(let statusString) = statusRaw,
                let status = QueryResultStatus(rawValue: statusString)
            else {
                throw SurrealError.invalidResponse("Missing query status at index \(index).")
            }

            guard let timeRaw = object["time"], case .string(let time) = timeRaw else {
                throw SurrealError.invalidResponse("Missing query time at index \(index).")
            }

            let result = object["result"] ?? .null
            let type = object["type"].flatMap(stringFromSurrealValue(_:))
            let kind = object["kind"].flatMap(stringFromSurrealValue(_:))
            let details = object["details"]

            return RPCQueryResult(
                status: status,
                time: time,
                result: result,
                type: type,
                kind: kind,
                details: details
            )
        }
    }

    static func decodeLiveEvent(from envelope: RPCResponseEnvelope) -> LiveWireEvent? {
        if
            let actionRaw = envelope.action,
            let action = LiveAction(rawValue: actionRaw),
            let id = envelope.id,
            let queryID = UUID(uuidString: id)
        {
            let payload = envelope.result ?? .none
            return LiveWireEvent(
                queryID: queryID,
                action: action,
                record: envelope.record.flatMap(nonEmpty) ?? liveRecordValue(fromPayload: payload),
                payload: payload
            )
        }

        guard let result = envelope.result else {
            return nil
        }
        return decodeLiveEvent(from: result)
    }

    /// Decodes a notification: `{ id, action, record, result, session? }`.
    /// `KILLED` carries no record and no result (both `NONE`), so neither is
    /// required; dropping those used to leave the stream open forever.
    static func decodeLiveEvent(from value: SurrealValue) -> LiveWireEvent? {
        guard case .object(let object) = value else {
            return nil
        }

        guard
            let idValue = object["id"],
            case .string(let actionRaw)? = object["action"],
            let action = LiveAction(rawValue: actionRaw),
            let queryID = uuidFromSurrealValue(idValue)
        else {
            return nil
        }

        let payload = object["result"] ?? .none
        let record = object["record"].flatMap(nonEmpty) ?? liveRecordValue(fromPayload: payload)

        return LiveWireEvent(
            queryID: queryID,
            action: action,
            record: record,
            payload: payload
        )
    }

    private static func nonEmpty(_ value: SurrealValue) -> SurrealValue? {
        switch value {
        case .none, .null: nil
        default: value
        }
    }

    private static func stringFromSurrealValue(_ value: SurrealValue) -> String? {
        if case .string(let string) = value {
            return string
        }
        return nil
    }

    private static func uuidFromSurrealValue(_ value: SurrealValue) -> UUID? {
        switch value {
        case .uuid(let uuid):
            return uuid
        case .string(let raw):
            return UUID(uuidString: raw)
        default:
            return nil
        }
    }

    private static func liveRecordValue(fromPayload payload: SurrealValue) -> SurrealValue? {
        switch payload {
        case .object(let object):
            return object["id"] ?? object["record"]
        case .string, .recordID:
            return payload
        default:
            return nil
        }
    }
}
