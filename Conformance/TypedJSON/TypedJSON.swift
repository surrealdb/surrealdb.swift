import Foundation
import SurrealDB

/// The typed JSON of surrealdb-protocol's spec/README.md, which its vectors,
/// scenarios and driver protocol all use to write SurrealDB values.
public enum TypedJSON {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// The names a single-key `$` object can carry. Any other `$` key is a
    /// plain object field.
    static let names: Set<String> = [
        "$none", "$int", "$float", "$i8", "$u8", "$i16", "$u16", "$i32", "$u32", "$u64", "$f16", "$f32",
        "$decimal", "$string", "$bytes", "$uuid", "$datetime", "$duration", "$array", "$object", "$set",
        "$table", "$record", "$range", "$file", "$geometry", "$regex"
    ]

    // MARK: - Typed JSON to SurrealValue

    public static func value(from json: JSONValue) throws -> SurrealValue {
        switch json {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .integer(let text):
            guard let value = Int64(text) else { throw Error("\(text) is beyond i64; typed JSON writes it as {$int: \"...\"}") }
            return .int(value)
        case .float(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(try values.map(value(from:)))
        case .object(let fields):
            if fields.count == 1, let entry = fields.first, names.contains(entry.key) {
                return try typed(entry.key, entry.value)
            }
            return .object(try fields.mapValues(value(from:)))
        }
    }

    private static func typed(_ key: String, _ json: JSONValue) throws -> SurrealValue {
        switch key {
        case "$none":
            return .none
        case "$int":
            return .int(try integer(json, Int64.self, key))
        case "$float":
            return .double(try float(json, key))
        case "$i8": return .sized(.i8(try integer(json, Int8.self, key)))
        case "$u8": return .sized(.u8(try integer(json, UInt8.self, key)))
        case "$i16": return .sized(.i16(try integer(json, Int16.self, key)))
        case "$u16": return .sized(.u16(try integer(json, UInt16.self, key)))
        case "$i32": return .sized(.i32(try integer(json, Int32.self, key)))
        case "$u32": return .sized(.u32(try integer(json, UInt32.self, key)))
        case "$u64": return .sized(.u64(try integer(json, UInt64.self, key)))
        case "$f16":
            let double = try float(json, key)
            guard let half = SurrealFloat16(exactly: double) else { throw Error("\(double) is not exactly an f16") }
            return .sized(.f16(half))
        case "$f32":
            let double = try float(json, key)
            let single = Float(double)
            guard Double(single).bitPattern == double.bitPattern || double.isNaN else {
                throw Error("\(double) is not exactly an f32")
            }
            return .sized(.f32(single))
        case "$decimal":
            return .decimal(try string(json, key))
        case "$string":
            return .string(try string(json, key))
        case "$bytes":
            return .bytes(try bytes(fromHex: string(json, key)))
        case "$uuid":
            let text = try string(json, key)
            guard let uuid = UUID(uuidString: text) else { throw Error("\(text) is not a UUID") }
            return .uuid(uuid)
        case "$datetime":
            let text = try string(json, key)
            guard let (seconds, nanos) = parseDatetime(text) else { throw Error("\(text) is not an RFC 3339 datetime") }
            return .datetime(date(seconds: seconds, nanoseconds: nanos))
        case "$duration":
            guard case .array(let parts) = json, parts.count == 2 else { throw Error("$duration takes [seconds, nanoseconds]") }
            return .duration(seconds: try integer(parts[0], UInt64.self, key), nanoseconds: try integer(parts[1], UInt32.self, key))
        case "$array":
            guard case .array(let values) = json else { throw Error("$array takes an array") }
            return .array(try values.map(value(from:)))
        case "$object":
            guard case .object(let fields) = json else { throw Error("$object takes an object") }
            return .object(try fields.mapValues(value(from:)))
        case "$set":
            guard case .array(let values) = json else { throw Error("$set takes an array") }
            return .set(try values.map(value(from:)))
        case "$table":
            return .table(try string(json, key))
        case "$record":
            guard case .object(let fields) = json, let table = fields["table"], let id = fields["key"] else {
                throw Error("$record takes {table, key}")
            }
            return .recordID(SurrealRecordID(table: try string(table, key), id: try value(from: id)))
        case "$range":
            guard case .object(let fields) = json else { throw Error("$range takes {start, end}") }
            return .range(SurrealRange(begin: try bound(fields["start"]), end: try bound(fields["end"])))
        case "$file":
            guard case .object(let fields) = json, let bucket = fields["bucket"], let path = fields["key"] else {
                throw Error("$file takes {bucket, key}")
            }
            return .file(SurrealFileRef(bucket: try string(bucket, key), key: try string(path, key)))
        case "$geometry":
            return .geometry(try geometry(json))
        default:
            throw Error("\(key) has no SurrealValue")
        }
    }

    private static func integer<T: FixedWidthInteger>(_ json: JSONValue, _ type: T.Type, _ key: String) throws -> T {
        let text: String
        switch json {
        case .integer(let value), .string(let value):
            text = value
        default:
            throw Error("\(key) takes an integer")
        }
        guard let value = T(text) else { throw Error("\(text) is out of range for \(key)") }
        return value
    }

    private static func float(_ json: JSONValue, _ key: String) throws -> Double {
        switch json {
        case .float(let value):
            return value
        case .integer(let text):
            guard let value = Double(text) else { throw Error("\(text) is not a number") }
            return value
        case .string("NaN"):
            return .nan
        case .string("Infinity"):
            return .infinity
        case .string("-Infinity"):
            return -.infinity
        case .string("-0"):
            return -0.0
        default:
            throw Error("\(key) takes a number or NaN, Infinity, -Infinity or -0")
        }
    }

    private static func string(_ json: JSONValue, _ key: String) throws -> String {
        guard case .string(let value) = json else { throw Error("\(key) takes a string") }
        return value
    }

    private static func bound(_ json: JSONValue?) throws -> SurrealRangeBound {
        switch json {
        case nil, .null?:
            return .unbounded
        case .object(let fields)? where fields.count == 1:
            if let value = fields["included"] { return .included(try self.value(from: value)) }
            if let value = fields["excluded"] { return .excluded(try self.value(from: value)) }
            fallthrough
        default:
            throw Error("a range bound is {included: v}, {excluded: v} or null")
        }
    }

    private static func geometry(_ json: JSONValue) throws -> SurrealGeometry {
        guard case .object(let fields) = json, case .string(let type)? = fields["type"] else {
            throw Error("$geometry takes a GeoJSON geometry")
        }
        if type == "GeometryCollection" {
            guard case .array(let members)? = fields["geometries"] else { throw Error("GeometryCollection needs geometries") }
            return .collection(try members.map(geometry))
        }
        guard let coordinates = fields["coordinates"] else { throw Error("\(type) needs coordinates") }
        switch type {
        case "Point": return .point(try numbers(coordinates))
        case "LineString": return .line(try nested(coordinates, numbers))
        case "Polygon": return .polygon(try nested(coordinates) { try nested($0, numbers) })
        case "MultiPoint": return .multiPoint(try nested(coordinates, numbers))
        case "MultiLineString": return .multiLine(try nested(coordinates) { try nested($0, numbers) })
        case "MultiPolygon": return .multiPolygon(try nested(coordinates) { try nested($0) { try nested($0, numbers) } })
        default: throw Error("unknown GeoJSON type \(type)")
        }
    }

    private static func nested<T>(_ json: JSONValue, _ element: (JSONValue) throws -> T) throws -> [T] {
        guard case .array(let values) = json else { throw Error("GeoJSON coordinates must be arrays") }
        return try values.map(element)
    }

    private static func numbers(_ json: JSONValue) throws -> [Double] {
        try nested(json) { try float($0, "coordinates") }
    }

    // MARK: - SurrealValue to typed JSON

    public static func json(from value: SurrealValue) -> JSONValue {
        switch value {
        case .none:
            return .object(["$none": .null])
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return abs(Double(value)) > 9_007_199_254_740_992 ? .object(["$int": .string(String(value))]) : .integer(String(value))
        case .double(let value):
            return .object(["$float": float(value)])
        case .sized(let number):
            let key = "$" + number.kindName
            switch number {
            case .f16(let half): return .object([key: float(half.doubleValue)])
            case .f32(let single): return .object([key: float(Double(single))])
            case .u64(let value) where value > 9_007_199_254_740_992: return .object([key: .string(String(value))])
            default: return .object([key: .integer(String(number.integer(as: Int64.self)!))])
            }
        case .string(let value):
            return .string(value)
        case .bytes(let data):
            return .object(["$bytes": .string(data.map { String(format: "%02x", $0) }.joined())])
        case .datetime(let date):
            return .object(["$datetime": .string(formatDatetime(date))])
        case .uuid(let uuid):
            return .object(["$uuid": .string(uuid.uuidString.lowercased())])
        case .decimal(let text):
            return .object(["$decimal": .string(normaliseDecimal(text))])
        case .duration:
            let (seconds, nanos) = value.durationComponents ?? (0, 0)
            let secondsJSON: JSONValue = seconds > 9_007_199_254_740_992 ? .string(String(seconds)) : .integer(String(seconds))
            return .object(["$duration": .array([secondsJSON, .integer(String(nanos))])])
        case .table(let name):
            return .object(["$table": .string(name)])
        case .recordID(let id):
            return .object(["$record": .object(["table": .string(id.table), "key": json(from: id.id)])])
        case .range(let range):
            return .object(["$range": .object(["start": json(from: range.begin), "end": json(from: range.end)])])
        case .set(let values):
            return .object(["$set": .array(values.map(json(from:)))])
        case .geometry(let geometry):
            return .object(["$geometry": json(from: geometry)])
        case .file(let file):
            return .object(["$file": .object(["bucket": .string(file.bucket), "key": .string(file.key)])])
        case .array(let values):
            return .array(values.map(json(from:)))
        case .object(let fields):
            let object = JSONValue.object(fields.mapValues(json(from:)))
            if fields.count == 1, let key = fields.keys.first, names.contains(key) {
                return .object(["$object": object])
            }
            return object
        }
    }

    private static func float(_ value: Double) -> JSONValue {
        if value.isNaN { return .string("NaN") }
        if value.isInfinite { return .string(value > 0 ? "Infinity" : "-Infinity") }
        if value == 0, value.sign == .minus { return .string("-0") }
        return .float(value)
    }

    private static func json(from bound: SurrealRangeBound) -> JSONValue {
        switch bound {
        case .included(let value): return .object(["included": json(from: value)])
        case .excluded(let value): return .object(["excluded": json(from: value)])
        case .unbounded: return .null
        }
    }

    private static func json(from geometry: SurrealGeometry) -> JSONValue {
        func numbers(_ values: [Double]) -> JSONValue { .array(values.map { .float($0) }) }
        switch geometry {
        case .point(let value):
            return .object(["type": .string("Point"), "coordinates": numbers(value)])
        case .line(let value):
            return .object(["type": .string("LineString"), "coordinates": .array(value.map(numbers))])
        case .polygon(let value):
            return .object(["type": .string("Polygon"), "coordinates": .array(value.map { .array($0.map(numbers)) })])
        case .multiPoint(let value):
            return .object(["type": .string("MultiPoint"), "coordinates": .array(value.map(numbers))])
        case .multiLine(let value):
            return .object(["type": .string("MultiLineString"), "coordinates": .array(value.map { .array($0.map(numbers)) })])
        case .multiPolygon(let value):
            return .object([
                "type": .string("MultiPolygon"),
                "coordinates": .array(value.map { .array($0.map { .array($0.map(numbers)) }) })
            ])
        case .collection(let members):
            return .object(["type": .string("GeometryCollection"), "geometries": .array(members.map(json(from:)))])
        }
    }

    // MARK: - Comparison

    /// Equality by the spec's rules: floats so that NaN equals NaN and -0
    /// differs from 0, sets without regard to order, decimals once
    /// normalised, and durations by their components.
    public static func equal(_ lhs: SurrealValue, _ rhs: SurrealValue) -> Bool {
        switch (lhs, rhs) {
        case (.double(let a), .double(let b)):
            return a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN)
        case (.sized(.f32(let a)), .sized(.f32(let b))):
            return a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN)
        case (.sized(.f16(let a)), .sized(.f16(let b))):
            return a == b || (a.isNaN && b.isNaN)
        case (.decimal(let a), .decimal(let b)):
            return normaliseDecimal(a) == normaliseDecimal(b)
        case (.duration, .duration):
            return lhs.durationComponents.map { [$0.seconds, UInt64($0.nanoseconds)] }
                == rhs.durationComponents.map { [$0.seconds, UInt64($0.nanoseconds)] }
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy(equal)
        case (.set(let a), .set(let b)):
            // Each element of one matched to a distinct element of the other.
            guard a.count == b.count else { return false }
            var unmatched = b
            for element in a {
                guard let index = unmatched.firstIndex(where: { equal(element, $0) }) else { return false }
                unmatched.remove(at: index)
            }
            return true
        case (.object(let a), .object(let b)):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
        case (.recordID(let a), .recordID(let b)):
            return a.table == b.table && equal(a.id, b.id)
        case (.range(let a), .range(let b)):
            return equal(a.begin, b.begin) && equal(a.end, b.end)
        case (.geometry(let a), .geometry(let b)):
            return json(from: a) == json(from: b)
        case (.datetime(let a), .datetime(let b)):
            return components(a) == components(b)
        default:
            return lhs == rhs
        }
    }

    private static func equal(_ lhs: SurrealRangeBound, _ rhs: SurrealRangeBound) -> Bool {
        switch (lhs, rhs) {
        case (.included(let a), .included(let b)), (.excluded(let a), .excluded(let b)):
            return equal(a, b)
        case (.unbounded, .unbounded):
            return true
        default:
            return false
        }
    }

    /// Strips trailing fractional zeros (and a bare point): `1.50` is `1.5`,
    /// `2.0` is `2`.
    public static func normaliseDecimal(_ text: String) -> String {
        guard text.contains("."), !text.lowercased().contains("e") else { return text }
        var trimmed = Substring(text)
        while trimmed.hasSuffix("0") { trimmed = trimmed.dropLast() }
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        return trimmed == "-0" ? "0" : String(trimmed)
    }

    // MARK: - Datetimes

    private static let unixToReferenceDate: Int64 = 978_307_200

    /// Whole seconds since 1970 (floored) and nanoseconds, the same split the
    /// codec sends in tag 12.
    public static func components(_ date: Date) -> (seconds: Int64, nanoseconds: UInt32) {
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

    public static func date(seconds: Int64, nanoseconds: UInt32) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(seconds - unixToReferenceDate) + Double(nanoseconds) / 1_000_000_000)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fffffffff]Z`, in UTC.
    static func parseDatetime(_ text: String) -> (Int64, UInt32)? {
        let pattern = #"^(-?\d{4,})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.(\d{1,9}))?Z$"#
        guard let match = text.range(of: pattern, options: .regularExpression), match == text.startIndex..<text.endIndex else {
            return nil
        }
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let year = Int64(group(1)!), let month = Int64(group(2)!), let day = Int64(group(3)!),
              let hour = Int64(group(4)!), let minute = Int64(group(5)!), let second = Int64(group(6)!)
        else {
            return nil
        }
        let fraction = group(8) ?? ""
        let nanos = UInt32(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0
        let days = daysFromCivil(year: year, month: month, day: day)
        return (days * 86_400 + hour * 3_600 + minute * 60 + second, nanos)
    }

    static func formatDatetime(_ date: Date) -> String {
        let (seconds, nanos) = components(date)
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 {
            rest += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        var text = String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld", year, month, day, rest / 3_600, rest % 3_600 / 60, rest % 60)
        if nanos != 0 {
            text += String(format: ".%09u", nanos)
        }
        return text + "Z"
    }

    // Howard Hinnant's proleptic Gregorian day counts.
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, month, day)
    }

    // MARK: - Bytes

    public static func bytes(fromHex text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else { throw Error("odd-length hex") }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw Error("bad hex \(text[index..<next])") }
            data.append(byte)
            index = next
        }
        return data
    }
}
