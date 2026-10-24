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
    /// The affected record, on a live notification sent at the top level.
    let record: SurrealValue?

    init(id: String?, action: String?, result: SurrealValue?, error: RPCErrorObject?, record: SurrealValue? = nil) {
        self.id = id
        self.action = action
        self.result = result
        self.error = error
        self.record = record
    }
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
            try params.forEach(checkEncodable)
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

        let id = try map.decoded("id").flatMap(stringFromSurrealValue(_:))
        let action = try map.decoded("action").flatMap(stringFromSurrealValue(_:))
        let result = try map.decoded("result")

        var error: RPCErrorObject?
        if let rawError = try map.decoded("error") {
            error = try decodeRPCError(from: rawError)
        }

        return RPCResponseEnvelope(id: id, action: action, result: result, error: error, record: try map.decoded("record"))
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
            // [seconds: i64, nanoseconds: u32]. Seconds are floored so the
            // nanoseconds always count forwards, which keeps dates before
            // 1970 intact (they used to be clamped to the epoch).
            let (seconds, nanos) = datetimeComponents(value)
            return .tagged(tagCustomDatetime, .array([
                cborInteger(seconds),
                .unsignedInt(UInt64(nanos)),
            ]))
        case .uuid(let value):
            return .tagged(.uuid, .byteString(withUnsafeBytes(of: value.uuid) { Data($0) }))
        case .decimal(let value):
            return .tagged(tagStringDecimal, .utf8String(value))
        case .duration(let value):
            // The server's own form: [seconds, nanoseconds], trailing zeros
            // dropped. Never tag 13 (a duration as text): SurrealDB 4.0
            // refuses it. Text that isn't a duration can't be sent, so
            // `encode` throws for it (`checkEncodable`) before getting here.
            guard let (seconds, nanos) = SurrealValue.duration(value).durationComponents else {
                return .utf8String(value)
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
            guard case .utf8String(let raw) = value, let date = SurrealValue.parseISO8601(raw) else {
                throw SurrealError.invalidResponse("Expected an RFC 3339 string for a datetime (tag 0).")
            }
            return .datetime(date)
        case .uuid:
            guard case .byteString(let data) = value, let uuid = UUID(uuidData: data) else {
                throw SurrealError.invalidResponse("Expected 16 bytes for a UUID (tag 37).")
            }
            return .uuid(uuid)
        case tagNone:
            return .none
        case tagTable:
            guard let name = stringFromCBOR(value) else {
                throw SurrealError.invalidResponse("Expected a string for a table name (tag 7).")
            }
            return .table(name)
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
            throw SurrealError.invalidResponse("Expected [table, key] for a record id (tag 8).")
        case tagStringUUID:
            // Used to fall back to a fresh random UUID.
            guard let text = stringFromCBOR(value), let uuid = UUID(uuidString: text) else {
                throw SurrealError.invalidResponse("Expected a UUID string (tag 9).")
            }
            return .uuid(uuid)
        case tagStringDecimal:
            guard let text = stringFromCBOR(value), SurrealValue.isDecimalText(text) else {
                throw SurrealError.invalidResponse("Expected a decimal string (tag 10).")
            }
            return .decimal(text)
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
            guard case .array(let parts) = value, parts.count == 2,
                  let seconds: Int64 = exactInteger(parts[0]),
                  let nanos: UInt32 = exactInteger(parts[1]), nanos < 1_000_000_000
            else {
                throw SurrealError.invalidResponse("Expected [seconds, nanoseconds] for a datetime (tag 12).")
            }
            return .datetime(date(seconds: seconds, nanoseconds: nanos))
        case tagRange:
            if case .array(let bounds) = value, bounds.count == 2 {
                let begin = try decodeBound(from: bounds[0])
                let end = try decodeBound(from: bounds[1])
                return .range(.init(begin: begin, end: end))
            }
            throw SurrealError.invalidResponse("Expected [begin, end] bounds for a range (tag 49).")
        case tagSet:
            guard case .array(let values) = value else {
                throw SurrealError.invalidResponse("Expected an array for a set (tag 56).")
            }
            return .set(try values.map(fromCBOR(_:)))
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

    private static let unixToReferenceDate: Int64 = 978_307_200

    /// Whether tag 12 can carry `date`: its whole seconds since 1970 must
    /// fit an `Int64` (with room for the 1970/2001 offset).
    static func canEncode(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.isFinite && seconds > -9.2e18 && seconds < 9.2e18
    }

    /// Throws for a value anywhere in `value` that has no wire form 4.0
    /// accepts: a datetime tag 12 can't carry, or a duration whose text
    /// doesn't parse. Tag 13 (a duration as text) used to carry the latter for
    /// the server to reject; 4.0 refuses that tag outright, so the SDK reports
    /// it itself.
    static func checkEncodable(_ value: SurrealValue) throws {
        switch value {
        case .datetime(let date) where !canEncode(date):
            throw EncodingError.invalidValue(date, .init(codingPath: [], debugDescription: "\(date) is out of range for a SurrealDB datetime."))
        case .duration(let text) where value.durationComponents == nil:
            throw EncodingError.invalidValue(text, .init(codingPath: [], debugDescription: "\"\(text)\" is not a valid SurrealDB duration (for example 1h30m, 500ms, 2w)."))
        case .array(let values), .set(let values):
            try values.forEach(checkEncodable)
        case .object(let fields):
            try fields.values.forEach(checkEncodable)
        case .recordID(let id):
            try checkEncodable(id.id)
        case .range(let range):
            for bound in [range.begin, range.end] {
                if case .included(let value) = bound { try checkEncodable(value) }
                if case .excluded(let value) = bound { try checkEncodable(value) }
            }
        default:
            break
        }
    }

    /// Splits a date into whole seconds since 1970 (floored) and nanoseconds.
    /// Works relative to 2001, where `Date` keeps its value, to lose as little
    /// precision as possible. Dates `canEncode` rejects are clamped, so this
    /// never traps; `encode` refuses them before getting here.
    static func datetimeComponents(_ date: Date) -> (seconds: Int64, nanoseconds: UInt32) {
        guard canEncode(date) else {
            return (date.timeIntervalSinceReferenceDate > 0 ? .max : .min, 0)
        }
        let sinceReference = date.timeIntervalSinceReferenceDate
        let whole = sinceReference.rounded(.down)
        var nanos = Int64(((sinceReference - whole) * 1_000_000_000).rounded())
        var seconds = Int64(whole) + unixToReferenceDate
        if nanos >= 1_000_000_000 {
            seconds += 1
            nanos -= 1_000_000_000
        }
        return (seconds, UInt32(nanos))
    }

    static func date(seconds: Int64, nanoseconds: UInt32) -> Date {
        // Seconds near Int64.min would overflow the subtraction; that far out
        // a Double can't tell the difference anyway.
        let (sinceReference, overflow) = seconds.subtractingReportingOverflow(unixToReferenceDate)
        let whole = overflow ? Double(seconds) - Double(unixToReferenceDate) : Double(sinceReference)
        return Date(timeIntervalSinceReferenceDate: whole + Double(nanoseconds) / 1_000_000_000)
    }

    static func cborInteger(_ value: Int64) -> CBOR {
        value >= 0 ? .unsignedInt(UInt64(value)) : .negativeInt(UInt64(bitPattern: ~value))
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
    /// The value under `key`, or `nil` if absent. A value that's present but
    /// malformed throws rather than reading as absent.
    func decoded(_ key: String) throws -> SurrealValue? {
        guard let cborValue = self[.utf8String(key)] else {
            return nil
        }
        return try CBORSurrealCodec.fromCBOR(cborValue)
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
    /// The record the notification is about; `nil` for `KILLED`.
    let record: SurrealValue?
    let payload: SurrealValue

    /// The record id as text, or `""` when there isn't one.
    var recordID: String {
        switch record {
        case .recordID(let id)?: id.rawValue
        case .string(let text)?: text
        default: ""
        }
    }
}
