import Foundation
import PotentCBOR

struct RPCRequest: Sendable {
    let id: String
    let method: String
    let params: [SurrealValue]?
    let session: String?
    let txn: String?
}

struct RPCResponseEnvelope: Sendable {
    let id: String?
    let action: String?
    let result: SurrealValue?
    let error: RPCErrorObject?
}

public struct RPCErrorCause: Sendable, Codable {
    public let message: String
    public let details: SurrealValue?
    public let kind: String?
    public let cause: SurrealValue?

    public init(message: String, details: SurrealValue?, kind: String?, cause: SurrealValue?) {
        self.message = message
        self.details = details
        self.kind = kind
        self.cause = cause
    }
}

public struct RPCErrorObject: Sendable, Codable {
    public let code: Int?
    public let kind: String?
    public let message: String
    public let details: SurrealValue?
    public let cause: RPCErrorCause?

    public init(code: Int?, kind: String?, message: String, details: SurrealValue?, cause: RPCErrorCause?) {
        self.code = code
        self.kind = kind
        self.message = message
        self.details = details
        self.cause = cause
    }
}

enum CBORSurrealCodec {
    static let tagNone = CBOR.Tag(rawValue: 6)
    static let tagTable = CBOR.Tag(rawValue: 7)
    static let tagRecordID = CBOR.Tag(rawValue: 8)
    static let tagStringUUID = CBOR.Tag(rawValue: 9)
    static let tagStringDecimal = CBOR.Tag(rawValue: 10)
    static let tagCustomDatetime = CBOR.Tag(rawValue: 12)
    static let tagStringDuration = CBOR.Tag(rawValue: 13)
    static let tagCustomDuration = CBOR.Tag(rawValue: 14)
    static let tagRange = CBOR.Tag(rawValue: 49)
    static let tagBoundIncluded = CBOR.Tag(rawValue: 50)
    static let tagBoundExcluded = CBOR.Tag(rawValue: 51)
    static let tagSet = CBOR.Tag(rawValue: 56)

    static let tagGeometryPoint = CBOR.Tag(rawValue: 88)
    static let tagGeometryLine = CBOR.Tag(rawValue: 89)
    static let tagGeometryPolygon = CBOR.Tag(rawValue: 90)
    static let tagGeometryMultiPoint = CBOR.Tag(rawValue: 91)
    static let tagGeometryMultiLine = CBOR.Tag(rawValue: 92)
    static let tagGeometryMultiPolygon = CBOR.Tag(rawValue: 93)
    static let tagGeometryCollection = CBOR.Tag(rawValue: 94)

    static func encode(_ request: RPCRequest) throws -> Data {
        var map = CBOR.Map()
        map[.utf8String("id")] = .utf8String(request.id)
        map[.utf8String("method")] = .utf8String(request.method)

        if let params = request.params {
            map[.utf8String("params")] = .array(params.map(toCBOR(_:)))
        }
        if let session = request.session {
            map[.utf8String("session")] = .utf8String(session)
        }
        if let txn = request.txn {
            map[.utf8String("txn")] = .utf8String(txn)
        }

        return try CBORSerialization.data(from: .map(map))
    }

    static func decodeRPCEnvelope(_ data: Data) throws -> RPCResponseEnvelope {
        let cbor = try CBORSerialization.cbor(from: data)
        guard case .map(let map) = cbor else {
            throw SurrealError.invalidResponse("Expected RPC response object.")
        }

        let id = map[string: "id"].flatMap(stringFromSurrealValue(_:))
        let action = map[string: "action"].flatMap(stringFromSurrealValue(_:))
        let result = map[string: "result"]

        var error: RPCErrorObject?
        if let rawError = map[string: "error"] {
            error = try decodeRPCError(from: rawError)
        }

        return RPCResponseEnvelope(id: id, action: action, result: result, error: error)
    }

    static func toCBOR(_ value: SurrealValue) -> CBOR {
        switch value {
        case .none:
            return .tagged(tagNone, .null)
        case .null:
            return .null
        case .bool(let value):
            return .boolean(value)
        case .int(let value):
            if value >= 0 {
                return .unsignedInt(UInt64(value))
            }
            return .negativeInt(UInt64(bitPattern: ~value))
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .utf8String(value)
        case .bytes(let value):
            return .byteString(value)
        case .datetime(let value):
            let seconds = Int64(value.timeIntervalSince1970)
            let nanos = Int64((value.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000)
            return .tagged(tagCustomDatetime, .array([
                .unsignedInt(UInt64(max(0, seconds))),
                .unsignedInt(UInt64(max(0, nanos))),
            ]))
        case .uuid(let value):
            return .tagged(.uuid, .byteString(withUnsafeBytes(of: value.uuid) { Data($0) }))
        case .decimal(let value):
            return .tagged(tagStringDecimal, .utf8String(value))
        case .duration(let value):
            // The server's own form: [seconds, nanoseconds], trailing zeros
            // dropped. Text that doesn't parse goes as a string, so the
            // server reports it rather than us guessing.
            guard let (seconds, nanos) = SurrealValue.duration(value).durationComponents else {
                return .tagged(tagStringDuration, .utf8String(value))
            }
            switch (seconds, nanos) {
            case (0, 0):
                return .tagged(tagCustomDuration, .array([]))
            case (_, 0):
                return .tagged(tagCustomDuration, .array([.unsignedInt(seconds)]))
            default:
                return .tagged(tagCustomDuration, .array([.unsignedInt(seconds), .unsignedInt(UInt64(nanos))]))
            }
        case .table(let value):
            return .tagged(tagTable, .utf8String(value))
        case .recordID(let value):
            return .tagged(tagRecordID, .array([
                .utf8String(value.table),
                toCBOR(value.id),
            ]))
        case .range(let value):
            return .tagged(tagRange, .array([
                toCBOR(bound: value.begin),
                toCBOR(bound: value.end),
            ]))
        case .set(let value):
            return .tagged(tagSet, .array(value.map(toCBOR(_:))))
        case .geometry(let value):
            switch value {
            case .point(let point):
                return .tagged(tagGeometryPoint, toCBORCoordinates(point))
            case .line(let line):
                return .tagged(tagGeometryLine, toCBORCoordinates(line))
            case .polygon(let polygon):
                return .tagged(tagGeometryPolygon, toCBORCoordinates(polygon))
            case .multiPoint(let points):
                return .tagged(tagGeometryMultiPoint, toCBORCoordinates(points))
            case .multiLine(let lines):
                return .tagged(tagGeometryMultiLine, toCBORCoordinates(lines))
            case .multiPolygon(let polygons):
                return .tagged(tagGeometryMultiPolygon, toCBORCoordinates(polygons))
            case .collection(let collection):
                return .tagged(tagGeometryCollection, .array(collection.map { toCBOR(.geometry($0)) }))
            }
        case .array(let value):
            return .array(value.map(toCBOR(_:)))
        case .object(let value):
            var map = CBOR.Map()
            for (key, value) in value {
                map[.utf8String(key)] = toCBOR(value)
            }
            return .map(map)
        }
    }

    static func fromCBOR(_ value: CBOR) throws -> SurrealValue {
        switch value {
        case .null:
            return .null
        case .undefined:
            return .none
        case .boolean(let value):
            return .bool(value)
        case .simple(let value):
            return .int(Int64(value))
        case .unsignedInt(let value):
            if value <= UInt64(Int64.max) {
                return .int(Int64(value))
            }
            return .double(Double(value))
        case .negativeInt(let value):
            return .int(Int64(bitPattern: ~value))
        case .half(let value):
            return .double(Double(value))
        case .float(let value):
            return .double(Double(value))
        case .double(let value):
            return .double(value)
        case .byteString(let value):
            return .bytes(value)
        case .utf8String(let value):
            return .string(value)
        case .array(let value):
            return .array(try value.map(fromCBOR(_:)))
        case .map(let value):
            var object: [String: SurrealValue] = [:]
            for (key, value) in value {
                guard case .utf8String(let stringKey) = key else {
                    continue
                }
                object[stringKey] = try fromCBOR(value)
            }
            return .object(object)
        case .tagged(let tag, let taggedValue):
            return try decodeTagged(tag: tag, value: taggedValue)
        }
    }

    private static func decodeRPCError(from value: SurrealValue) throws -> RPCErrorObject {
        guard case .object(let object) = value else {
            throw SurrealError.invalidResponse("Expected RPC error object.")
        }

        let code = object["code"].flatMap(intFromSurrealValue(_:))
        let kind = object["kind"].flatMap(stringFromSurrealValue(_:))
        let message = object["message"].flatMap(stringFromSurrealValue(_:)) ?? "Unknown RPC error"
        let details = object["details"]
        let cause = try object["cause"].map(decodeRPCCause(from:))

        return RPCErrorObject(code: code, kind: kind, message: message, details: details, cause: cause)
    }

    private static func decodeRPCCause(from value: SurrealValue) throws -> RPCErrorCause {
        guard case .object(let object) = value else {
            throw SurrealError.invalidResponse("Expected RPC error cause object.")
        }

        let message = object["message"].flatMap(stringFromSurrealValue(_:)) ?? "Unknown cause"
        let details = object["details"]
        let kind = object["kind"].flatMap(stringFromSurrealValue(_:))
        let cause = object["cause"]

        return RPCErrorCause(message: message, details: details, kind: kind, cause: cause)
    }

    private static func decodeTagged(tag: CBOR.Tag, value: CBOR) throws -> SurrealValue {
        switch tag {
        case .iso8601DateTime:
            guard case .utf8String(let raw) = value,
                  let date = ISO8601DateFormatter().date(from: raw)
            else {
                return .null
            }
            return .datetime(date)
        case .uuid:
            guard case .byteString(let data) = value,
                  let uuid = UUID(uuidData: data)
            else {
                return .null
            }
            return .uuid(uuid)
        case tagNone:
            return .none
        case tagTable:
            return .table(stringFromCBOR(value) ?? "")
        case tagRecordID:
            if case .utf8String(let raw) = value {
                let pieces = raw.split(separator: ":", maxSplits: 1)
                if pieces.count == 2 {
                    return .recordID(.init(table: String(pieces[0]), id: .string(String(pieces[1]))))
                }
                return .string(raw)
            }
            if case .array(let items) = value,
               items.count == 2,
               case .utf8String(let table) = items[0] {
                return .recordID(.init(table: table, id: try fromCBOR(items[1])))
            }
            return .null
        case tagStringUUID:
            return .uuid(UUID(uuidString: stringFromCBOR(value) ?? "") ?? UUID())
        case tagStringDecimal:
            return .decimal(stringFromCBOR(value) ?? "0")
        case tagStringDuration:
            guard let text = stringFromCBOR(value) else {
                throw SurrealError.invalidResponse("Expected a string for a tagged duration (tag 13).")
            }
            return .duration(text)
        case tagCustomDuration:
            // [seconds?, nanoseconds?]: either may be left out when zero.
            guard case .array(let parts) = value, parts.count <= 2 else {
                throw SurrealError.invalidResponse("Expected an array of at most two integers for a duration (tag 14).")
            }
            var seconds: UInt64 = 0
            var nanos: UInt32 = 0
            if parts.count > 0 {
                guard let value: UInt64 = exactInteger(parts[0]) else {
                    throw SurrealError.invalidResponse("Duration seconds must be a non-negative integer.")
                }
                seconds = value
            }
            if parts.count > 1 {
                guard let value: UInt32 = exactInteger(parts[1]), value < 1_000_000_000 else {
                    throw SurrealError.invalidResponse("Duration nanoseconds must be an integer from 0 to 999999999.")
                }
                nanos = value
            }
            return .duration(seconds: seconds, nanoseconds: nanos)
        case tagCustomDatetime:
            if case .array(let parts) = value, parts.count == 2 {
                let sec = parts[0].integerValue() ?? 0
                let nsec = parts[1].integerValue() ?? 0
                let date = Date(timeIntervalSince1970: Double(sec) + (Double(nsec) / 1_000_000_000))
                return .datetime(date)
            }
            return .null
        case tagRange:
            if case .array(let bounds) = value, bounds.count == 2 {
                let begin = try decodeBound(from: bounds[0])
                let end = try decodeBound(from: bounds[1])
                return .range(.init(begin: begin, end: end))
            }
            return .null
        case tagSet:
            if case .array(let values) = value {
                return .set(try values.map(fromCBOR(_:)))
            }
            return .set([])
        case tagGeometryPoint:
            return .geometry(.point(doubleArray(from: value)))
        case tagGeometryLine:
            return .geometry(.line(doubleArray2(from: value)))
        case tagGeometryPolygon:
            return .geometry(.polygon(doubleArray3(from: value)))
        case tagGeometryMultiPoint:
            return .geometry(.multiPoint(doubleArray2(from: value)))
        case tagGeometryMultiLine:
            return .geometry(.multiLine(doubleArray3(from: value)))
        case tagGeometryMultiPolygon:
            return .geometry(.multiPolygon(doubleArray4(from: value)))
        case tagGeometryCollection:
            if case .array(let values) = value {
                let geometries = try values.compactMap { item -> SurrealGeometry? in
                    guard case .geometry(let geometry) = try fromCBOR(item) else {
                        return nil
                    }
                    return geometry
                }
                return .geometry(.collection(geometries))
            }
            return .geometry(.collection([]))
        default:
            return try fromCBOR(value)
        }
    }

    private static func toCBOR(bound: SurrealRangeBound) -> CBOR {
        switch bound {
        case .included(let value):
            return .tagged(tagBoundIncluded, toCBOR(value))
        case .excluded(let value):
            return .tagged(tagBoundExcluded, toCBOR(value))
        case .unbounded:
            return .null
        }
    }

    private static func decodeBound(from cbor: CBOR) throws -> SurrealRangeBound {
        switch cbor {
        case .null:
            return .unbounded
        case .tagged(let tag, let value) where tag == tagBoundIncluded:
            return .included(try fromCBOR(value))
        case .tagged(let tag, let value) where tag == tagBoundExcluded:
            return .excluded(try fromCBOR(value))
        default:
            return .included(try fromCBOR(cbor))
        }
    }

    private static func toCBORCoordinates(_ value: [Double]) -> CBOR {
        .array(value.map { .double($0) })
    }

    private static func toCBORCoordinates(_ value: [[Double]]) -> CBOR {
        .array(value.map(toCBORCoordinates(_:)))
    }

    private static func toCBORCoordinates(_ value: [[[Double]]]) -> CBOR {
        .array(value.map(toCBORCoordinates(_:)))
    }

    private static func toCBORCoordinates(_ value: [[[[Double]]]]) -> CBOR {
        .array(value.map(toCBORCoordinates(_:)))
    }

    private static func doubleArray(from value: CBOR) -> [Double] {
        guard case .array(let values) = value else {
            return []
        }
        return values.compactMap { $0.floatingPointValue() }
    }

    private static func doubleArray2(from value: CBOR) -> [[Double]] {
        guard case .array(let values) = value else {
            return []
        }
        return values.map(doubleArray(from:))
    }

    private static func doubleArray3(from value: CBOR) -> [[[Double]]] {
        guard case .array(let values) = value else {
            return []
        }
        return values.map(doubleArray2(from:))
    }

    private static func doubleArray4(from value: CBOR) -> [[[[Double]]]] {
        guard case .array(let values) = value else {
            return []
        }
        return values.map(doubleArray3(from:))
    }

    /// PotentCBOR's `integerValue()` traps when the value doesn't fit `T`.
    static func exactInteger<T: BinaryInteger>(_ value: CBOR) -> T? {
        switch value {
        case .unsignedInt(let uint):
            return T(exactly: uint)
        case .negativeInt(let nint):
            // CBOR stores -1 - n; n == UInt64.max is below Int64.min.
            guard nint <= UInt64(Int64.max) else { return nil }
            return T(exactly: -1 - Int64(nint))
        default:
            return nil
        }
    }

    private static func stringFromCBOR(_ value: CBOR) -> String? {
        if case .utf8String(let string) = value {
            return string
        }
        return nil
    }

    private static func stringFromSurrealValue(_ value: SurrealValue) -> String? {
        if case .string(let string) = value {
            return string
        }
        return nil
    }

    private static func intFromSurrealValue(_ value: SurrealValue) -> Int? {
        if case .int(let int) = value {
            return Int(int)
        }
        return nil
    }

}

private extension CBOR.Map {
    subscript(string key: String) -> SurrealValue? {
        guard let cborValue = self[.utf8String(key)] else {
            return nil
        }
        return try? CBORSurrealCodec.fromCBOR(cborValue)
    }
}

private extension UUID {
    init?(uuidData data: Data) {
        guard data.count == 16 else {
            return nil
        }
        self = data.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }
}

struct LiveWireEvent: Sendable {
    let queryID: UUID
    let action: LiveAction
    let recordID: String
    let payload: SurrealValue
}
