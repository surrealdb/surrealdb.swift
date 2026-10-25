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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        message = try container.decode(String.self, forKey: .message)
        details = try container.decodeIfPresent(SurrealValue.self, forKey: .details)
        // As over CBOR: a string or null cause mustn't fail the whole error.
        cause = try container.decodeIfPresent(SurrealValue.self, forKey: .cause)
            .flatMap(CBORSurrealCodec.decodeRPCCause(from:))
    }
}

/// Which CBOR a connection speaks. `cbor.2` is plain `cbor` plus tags 180 to
/// 188, which SurrealDB 4.0 uses for its sized numbers; for every other value
/// the bytes are the same.
enum CBORDialect: Sendable, Hashable {
    case cbor
    case cbor2
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
    static let tagFile = CBOR.Tag(rawValue: 55)
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

    static let tagI8 = CBOR.Tag(rawValue: 180)
    static let tagU8 = CBOR.Tag(rawValue: 181)
    static let tagI16 = CBOR.Tag(rawValue: 182)
    static let tagU16 = CBOR.Tag(rawValue: 183)
    static let tagI32 = CBOR.Tag(rawValue: 184)
    static let tagU32 = CBOR.Tag(rawValue: 185)
    static let tagU64 = CBOR.Tag(rawValue: 186)
    static let tagF16 = CBOR.Tag(rawValue: 187)
    static let tagF32 = CBOR.Tag(rawValue: 188)

    static func encode(_ request: RPCRequest, dialect: CBORDialect = .cbor) throws -> Data {
        var map = CBOR.Map()
        map[.utf8String("id")] = .utf8String(request.id)
        map[.utf8String("method")] = .utf8String(request.method)

        if let params = request.params {
            try params.forEach(checkEncodable)
            map[.utf8String("params")] = .array(params.map { toCBOR($0, dialect: dialect) })
        }
        if let session = request.session {
            map[.utf8String("session")] = .utf8String(session)
        }
        if let txn = request.txn {
            map[.utf8String("txn")] = .utf8String(txn)
        }

        return try CBORSerialization.data(from: .map(map))
    }

    /// Decodes a CBOR body that holds a single value.
    static func decodeValue(_ data: Data, dialect: CBORDialect = .cbor) throws -> SurrealValue {
        try CBORStructure.checkDuplicateKeys(data)
        return try fromCBOR(CBORSerialization.cbor(from: data), dialect: dialect)
    }

    static func decodeRPCEnvelope(_ data: Data, dialect: CBORDialect = .cbor) throws -> RPCResponseEnvelope {
        try CBORStructure.checkDuplicateKeys(data)
        let cbor = try CBORSerialization.cbor(from: data)
        guard case .map(let map) = cbor else {
            throw SurrealError.invalidResponse("Expected RPC response object.")
        }

        let id = try map.decoded("id", dialect).flatMap(stringFromSurrealValue(_:))
        let action = try map.decoded("action", dialect).flatMap(stringFromSurrealValue(_:))
        let result = try map.decoded("result", dialect)

        var error: RPCErrorObject?
        if let rawError = try map.decoded("error", dialect) {
            error = try decodeRPCError(from: rawError)
        }

        return RPCResponseEnvelope(id: id, action: action, result: result, error: error, record: try map.decoded("record", dialect))
    }

    static func toCBOR(_ value: SurrealValue, dialect: CBORDialect = .cbor) -> CBOR {
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
        case .sized(let number):
            // Plain cbor has no sized numbers: widen them, as the server does.
            guard dialect == .cbor2 else {
                return toCBOR(number.widened, dialect: dialect)
            }
            return toCBOR(sized: number)
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
            // dropped. `checkEncodable` refuses text that doesn't parse
            // before it gets here; tag 13, the text form, is refused from
            // 4.0 on.
            let (seconds, nanos) = SurrealValue.duration(value).durationComponents ?? (0, 0)
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
                toCBOR(value.id, dialect: dialect),
            ]))
        case .range(let value):
            return .tagged(tagRange, .array([
                toCBOR(bound: value.begin, dialect: dialect),
                toCBOR(bound: value.end, dialect: dialect),
            ]))
        case .set(let value):
            return .tagged(tagSet, .array(value.map { toCBOR($0, dialect: dialect) }))
        case .file(let value):
            return .tagged(tagFile, .array([.utf8String(value.bucket), .utf8String(value.key)]))
        case .geometry(let value):
            switch value {
            // The server's form: every point, line and polygon inside
            // another geometry carries its own tag.
            case .point(let point):
                return cborPoint(point)
            case .line(let line):
                return cborLine(line)
            case .polygon(let polygon):
                return cborPolygon(polygon)
            case .multiPoint(let points):
                return .tagged(tagGeometryMultiPoint, .array(points.map(cborPoint)))
            case .multiLine(let lines):
                return .tagged(tagGeometryMultiLine, .array(lines.map(cborLine)))
            case .multiPolygon(let polygons):
                return .tagged(tagGeometryMultiPolygon, .array(polygons.map(cborPolygon)))
            case .collection(let collection):
                return .tagged(tagGeometryCollection, .array(collection.map { toCBOR(.geometry($0)) }))
            }
        case .array(let value):
            return .array(value.map { toCBOR($0, dialect: dialect) })
        case .object(let value):
            var map = CBOR.Map()
            for (key, value) in value {
                map[.utf8String(key)] = toCBOR(value, dialect: dialect)
            }
            return .map(map)
        }
    }

    private static func toCBOR(sized number: SurrealSizedNumber) -> CBOR {
        switch number {
        case .i8(let value):
            return .tagged(tagI8, cborInteger(Int64(value)))
        case .u8(let value):
            return .tagged(tagU8, .unsignedInt(UInt64(value)))
        case .i16(let value):
            return .tagged(tagI16, cborInteger(Int64(value)))
        case .u16(let value):
            return .tagged(tagU16, .unsignedInt(UInt64(value)))
        case .i32(let value):
            return .tagged(tagI32, cborInteger(Int64(value)))
        case .u32(let value):
            return .tagged(tagU32, .unsignedInt(UInt64(value)))
        case .u64(let value):
            return .tagged(tagU64, .unsignedInt(value))
        case .f16(let value):
            return .tagged(tagF16, .half(CBOR.Half(bitPattern: value.bitPattern)))
        case .f32(let value):
            return .tagged(tagF32, .float(value))
        }
    }

    static func fromCBOR(_ value: CBOR, dialect: CBORDialect = .cbor) throws -> SurrealValue {
        switch value {
        case .null:
            return .null
        case .undefined:
            return .none
        case .boolean(let value):
            return .bool(value)
        case .simple(let value):
            return .int(Int64(value))
        case .unsignedInt, .negativeInt:
            // An untagged integer is an i64; the server refuses any other.
            guard let int: Int64 = exactInteger(value) else {
                throw SurrealError.invalidResponse("CBOR integer \(value) is outside i64.")
            }
            return .int(int)
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
            return .array(try value.map { try fromCBOR($0, dialect: dialect) })
        case .map(let value):
            var object: [String: SurrealValue] = [:]
            for (key, value) in value {
                guard case .utf8String(let stringKey) = key else {
                    throw SurrealError.invalidResponse("CBOR map keys must be strings.")
                }
                object[stringKey] = try fromCBOR(value, dialect: dialect)
            }
            return .object(object)
        case .tagged(let tag, let taggedValue):
            return try decodeTagged(tag: tag, value: taggedValue, dialect: dialect)
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
        let cause = object["cause"].flatMap(decodeRPCCause(from:))

        return RPCErrorObject(code: code, kind: kind, message: message, details: details, cause: cause)
    }

    /// The server sends `cause` as an object, a plain message, or NONE when
    /// there isn't one. It's extra detail on an error we already have, so
    /// anything else is dropped rather than failing the response.
    static func decodeRPCCause(from value: SurrealValue) -> RPCErrorCause? {
        let object: [String: SurrealValue]
        switch value {
        case .object(let value):
            object = value
        case .string(let message):
            return RPCErrorCause(message: message, details: nil, kind: nil, cause: nil)
        default:
            return nil
        }

        let message = object["message"].flatMap(stringFromSurrealValue(_:)) ?? "Unknown cause"
        let details = object["details"]
        let kind = object["kind"].flatMap(stringFromSurrealValue(_:))
        let cause = object["cause"]

        return RPCErrorCause(message: message, details: details, kind: kind, cause: cause)
    }

    private static func decodeTagged(tag: CBOR.Tag, value: CBOR, dialect: CBORDialect) throws -> SurrealValue {
        let fromCBOR = { (item: CBOR) in try Self.fromCBOR(item, dialect: dialect) }
        switch tag {
        case .iso8601DateTime, tagStringUUID, tagStringDuration:
            // The text forms. Servers send tags 12, 37 and 14, and 4.0
            // refuses these.
            throw SurrealError.invalidResponse("CBOR tag \(tag.rawValue) (a value as text) is not accepted; expected tag 12, 37 or 14.")
        case .uuid:
            guard case .byteString(let data) = value, let uuid = UUID(uuidData: data) else {
                throw SurrealError.invalidResponse("Expected 16 bytes for a UUID (tag 37).")
            }
            return .uuid(uuid)
        case tagNone:
            guard case .null = value else {
                throw SurrealError.invalidResponse("Expected null inside NONE (tag 6).")
            }
            return .none
        case tagTable:
            guard let name = stringFromCBOR(value) else {
                throw SurrealError.invalidResponse("Expected a string for a table name (tag 7).")
            }
            return .table(name)
        case tagRecordID:
            if case .utf8String(let raw) = value {
                return .recordID(try RecordIDText.parse(raw))
            }
            if case .array(let items) = value,
               items.count == 2,
               case .utf8String(let table) = items[0] {
                return .recordID(.init(table: table, id: try recordKey(fromCBOR(items[1]))))
            }
            throw SurrealError.invalidResponse("Expected [table, key] for a record id (tag 8).")
        case tagStringDecimal:
            guard let text = stringFromCBOR(value), SurrealValue.isDecimalText(text), DecimalText.fits(text) else {
                throw SurrealError.invalidResponse("Expected a decimal of at most 96 bits and 28 places (tag 10).")
            }
            return .decimal(text)
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
            guard datetimeSeconds.contains(seconds) else {
                throw SurrealError.invalidResponse("Datetime (tag 12) is outside the years -262143 to 262142.")
            }
            return .datetime(date(seconds: seconds, nanoseconds: nanos))
        case tagFile:
            guard case .array(let parts) = value, parts.count == 2,
                  case .utf8String(let bucket) = parts[0], case .utf8String(let key) = parts[1]
            else {
                throw SurrealError.invalidResponse("Expected [bucket, key] strings for a file (tag 55).")
            }
            return .file(SurrealFileRef(bucket: bucket, key: key))
        case tagRange:
            if case .array(let bounds) = value, bounds.count == 2 {
                let begin = try decodeBound(from: bounds[0], dialect: dialect)
                let end = try decodeBound(from: bounds[1], dialect: dialect)
                return .range(.init(begin: begin, end: end))
            }
            throw SurrealError.invalidResponse("Expected [begin, end] bounds for a range (tag 49).")
        case tagSet:
            guard case .array(let values) = value else {
                throw SurrealError.invalidResponse("Expected an array for a set (tag 56).")
            }
            // The server deduplicates whatever it receives; so does this.
            var seen = Set<SurrealValue>()
            return .set(try values.map(fromCBOR).filter { seen.insert($0).inserted })
        case tagGeometryPoint:
            return .geometry(.point(try point(value)))
        case tagGeometryLine:
            return .geometry(.line(try line(value)))
        case tagGeometryPolygon:
            return .geometry(.polygon(try polygon(value)))
        case tagGeometryMultiPoint:
            return .geometry(.multiPoint(try members(of: value, tag: tagGeometryPoint, point)))
        case tagGeometryMultiLine:
            return .geometry(.multiLine(try members(of: value, tag: tagGeometryLine, line)))
        case tagGeometryMultiPolygon:
            return .geometry(.multiPolygon(try members(of: value, tag: tagGeometryPolygon, polygon)))
        case tagGeometryCollection:
            guard case .array(let values) = value else {
                throw SurrealError.invalidResponse("Expected an array of geometries (tag 94).")
            }
            return .geometry(.collection(try values.map { item in
                guard case .geometry(let geometry) = try fromCBOR(item) else {
                    throw SurrealError.invalidResponse("Expected a geometry inside a collection (tag 94).")
                }
                return geometry
            }))
        case tagI8, tagU8, tagI16, tagU16, tagI32, tagU32, tagU64, tagF16, tagF32:
            guard dialect == .cbor2 else {
                throw SurrealError.invalidResponse("CBOR tag \(tag.rawValue) (a sized number) is only valid on cbor.2.")
            }
            return .sized(try decodeSized(tag: tag, value: value))
        default:
            throw SurrealError.invalidResponse("Unknown CBOR tag \(tag.rawValue).")
        }
    }

    /// The width rules the server applies: an integer tag needs a CBOR
    /// integer within the kind's range, and a float tag a CBOR float (of any
    /// width) that the kind holds exactly.
    private static func decodeSized(tag: CBOR.Tag, value: CBOR) throws -> SurrealSizedNumber {
        func integer<T: FixedWidthInteger>(_ type: T.Type, _ kind: String) throws -> T {
            guard let result: T = exactInteger(value) else {
                throw SurrealError.invalidResponse("Expected an integer within \(kind) for CBOR tag \(tag.rawValue).")
            }
            return result
        }
        func float(_ kind: String) throws -> Double {
            switch value {
            case .half(let half): return Double(half)
            case .float(let float): return Double(float)
            case .double(let double): return double
            default: throw SurrealError.invalidResponse("Expected a float for CBOR tag \(tag.rawValue) (\(kind)).")
            }
        }
        switch tag {
        case tagI8: return .i8(try integer(Int8.self, "i8"))
        case tagU8: return .u8(try integer(UInt8.self, "u8"))
        case tagI16: return .i16(try integer(Int16.self, "i16"))
        case tagU16: return .u16(try integer(UInt16.self, "u16"))
        case tagI32: return .i32(try integer(Int32.self, "i32"))
        case tagU32: return .u32(try integer(UInt32.self, "u32"))
        case tagU64: return .u64(try integer(UInt64.self, "u64"))
        case tagF16:
            guard let half = SurrealFloat16(exactly: try float("f16")) else {
                throw SurrealError.invalidResponse("CBOR tag 187 holds a float that isn't exactly an f16.")
            }
            return .f16(half)
        default:
            let double = try float("f32")
            let single = Float(double)
            guard Double(single).bitPattern == double.bitPattern || double.isNaN else {
                throw SurrealError.invalidResponse("CBOR tag 188 holds a float that isn't exactly an f32.")
            }
            return .f32(single)
        }
    }

    /// A record id key is an int, string, UUID, array, object or a range of
    /// keys. It holds an i64, so a sized integer key is a plain int key, and
    /// a sized float key isn't a key at all. (Inside an array or object key
    /// the width is kept.)
    private static func recordKey(_ key: SurrealValue) throws -> SurrealValue {
        switch key {
        case .int, .string, .uuid, .array, .object:
            return key
        case .range(let range):
            func bound(_ bound: SurrealRangeBound) throws -> SurrealRangeBound {
                switch bound {
                case .included(let value): .included(try recordKey(value))
                case .excluded(let value): .excluded(try recordKey(value))
                case .unbounded: .unbounded
                }
            }
            return .range(SurrealRange(begin: try bound(range.begin), end: try bound(range.end)))
        case .sized(let number):
            guard let int = number.integer(as: Int64.self) else {
                throw SurrealError.invalidResponse("A \(number.kindName) can't be a record id key.")
            }
            return .int(int)
        default:
            throw SurrealError.invalidResponse("A record id key must be an int, string, UUID, array, object or range.")
        }
    }

    private static func toCBOR(bound: SurrealRangeBound, dialect: CBORDialect) -> CBOR {
        switch bound {
        case .included(let value):
            return .tagged(tagBoundIncluded, toCBOR(value, dialect: dialect))
        case .excluded(let value):
            return .tagged(tagBoundExcluded, toCBOR(value, dialect: dialect))
        case .unbounded:
            return .null
        }
    }

    private static func decodeBound(from cbor: CBOR, dialect: CBORDialect) throws -> SurrealRangeBound {
        switch cbor {
        case .null:
            return .unbounded
        case .tagged(let tag, let value) where tag == tagBoundIncluded:
            return .included(try fromCBOR(value, dialect: dialect))
        case .tagged(let tag, let value) where tag == tagBoundExcluded:
            return .excluded(try fromCBOR(value, dialect: dialect))
        default:
            throw SurrealError.invalidResponse("A range bound must be tag 50, tag 51 or null.")
        }
    }

    private static func cborPoint(_ point: [Double]) -> CBOR {
        .tagged(tagGeometryPoint, .array(point.map { .double($0) }))
    }

    private static func cborLine(_ line: [[Double]]) -> CBOR {
        .tagged(tagGeometryLine, .array(line.map(cborPoint)))
    }

    private static func cborPolygon(_ polygon: [[[Double]]]) -> CBOR {
        .tagged(tagGeometryPolygon, .array(polygon.map(cborLine)))
    }

    /// A point's `[x, y]`. Coordinates may arrive as integers.
    private static func point(_ value: CBOR) throws -> [Double] {
        guard case .array(let items) = value, items.count == 2 else {
            throw SurrealError.invalidResponse("Expected [x, y] for a point (tag 88).")
        }
        return try items.map { item in
            switch item {
            case .half(let half): return Double(half)
            case .float(let float): return Double(float)
            case .double(let double): return double
            default:
                guard let int: Int64 = exactInteger(item) else {
                    throw SurrealError.invalidResponse("Expected a number for a point coordinate (tag 88).")
                }
                return Double(int)
            }
        }
    }

    private static func line(_ value: CBOR) throws -> [[Double]] {
        try members(of: value, tag: tagGeometryPoint, point)
    }

    /// A polygon's rings. The server closes an open ring by repeating its
    /// first point, and so does this.
    private static func polygon(_ value: CBOR) throws -> [[[Double]]] {
        let rings = try members(of: value, tag: tagGeometryLine, line)
        guard !rings.isEmpty else {
            throw SurrealError.invalidResponse("A polygon (tag 90) needs at least one ring.")
        }
        return rings.map { ring in
            guard let first = ring.first, ring.last != first else { return ring }
            return ring + [first]
        }
    }

    /// The members of a geometry array, each in its own tag (`tag`) as the
    /// server sends them, or bare.
    private static func members<T>(of value: CBOR, tag: CBOR.Tag, _ member: (CBOR) throws -> T) throws -> [T] {
        guard case .array(let items) = value else {
            throw SurrealError.invalidResponse("Expected an array inside a geometry.")
        }
        return try items.map { item in
            if case .tagged(let itemTag, let inner) = item {
                guard itemTag == tag else {
                    throw SurrealError.invalidResponse("Expected CBOR tag \(tag.rawValue) inside a geometry, not \(itemTag.rawValue).")
                }
                return try member(inner)
            }
            return try member(item)
        }
    }

    private static let unixToReferenceDate: Int64 = 978_307_200

    /// The whole seconds since 1970 a datetime can have: the server's range,
    /// -262143-01-01T00:00:00Z to +262142-12-31T23:59:59.999999999Z.
    static let datetimeSeconds: ClosedRange<Int64> = -8_334_601_228_800...8_210_266_876_799

    /// Whether tag 12 can carry `date`: it must be within `datetimeSeconds`.
    static func canEncode(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else { return false }
        let unix = seconds.rounded(.down) + Double(unixToReferenceDate)
        return unix >= Double(datetimeSeconds.lowerBound) && unix <= Double(datetimeSeconds.upperBound)
    }

    /// Throws for a value anywhere in `value` that has no CBOR form the
    /// server accepts: a datetime tag 12 can't carry, duration text that
    /// doesn't parse, or a decimal that isn't one.
    static func checkEncodable(_ value: SurrealValue) throws {
        switch value {
        case .datetime(let date) where !canEncode(date):
            throw EncodingError.invalidValue(date, .init(codingPath: [], debugDescription: "\(date) is out of range for a SurrealDB datetime."))
        case .duration(let text) where value.durationComponents == nil:
            throw EncodingError.invalidValue(text, .init(codingPath: [], debugDescription: "\(text) is not a SurrealDB duration."))
        case .decimal(let text) where !(SurrealValue.isDecimalText(text) && DecimalText.fits(text)):
            throw EncodingError.invalidValue(text, .init(codingPath: [], debugDescription: "\(text) is not a SurrealDB decimal."))
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
    func decoded(_ key: String, _ dialect: CBORDialect) throws -> SurrealValue? {
        guard let cborValue = self[.utf8String(key)] else {
            return nil
        }
        return try CBORSurrealCodec.fromCBOR(cborValue, dialect: dialect)
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
