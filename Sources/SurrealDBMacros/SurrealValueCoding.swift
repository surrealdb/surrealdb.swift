import Foundation

// Converts between `SurrealValue` and Codable types directly, without a
// detour through JSON. JSON has no record ids, datetimes, UUIDs, durations or
// bytes, so the old round trip turned all of them into strings and dropped
// sub-second precision.
//
// Decoding is lenient where it loses nothing: a record id, UUID, duration,
// decimal, table or datetime decodes into a `String` as its text form, so
// models with `let id: String` keep working; numbers convert when the value
// fits exactly.

extension SurrealValue {
    /// Decodes a Codable type straight from this value.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try SurrealValueDecoder.unbox(self, as: T.self, codingPath: [])
    }

    /// Encodes a Codable value straight into a `SurrealValue`. `Date`, `UUID`,
    /// `Data`, `Decimal`, `SurrealRecordID` and `SurrealValue` keep their
    /// SurrealDB types.
    public static func fromEncodable<T: Encodable>(_ value: T) throws -> SurrealValue {
        try SurrealValueEncoder.box(value, codingPath: [])
    }

    /// Decodes through JSON with the given decoder. Lossy: kept only for code
    /// that relies on a custom `JSONDecoder` strategy.
    @available(*, deprecated, message: "Lossy: decodes through JSON. Use decode(_:) instead.")
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder) throws -> T {
        let object = try jsonObject()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: data)
    }

    /// Encodes through JSON with the given encoder. Lossy: kept only for code
    /// that relies on a custom `JSONEncoder` strategy.
    @available(*, deprecated, message: "Lossy: encodes through JSON. Use fromEncodable(_:) instead.")
    public static func fromEncodable<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> SurrealValue {
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try SurrealValue(jsonObject: object)
    }
}

// MARK: - Decoding

struct SurrealCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "Index \(intValue)"
        self.intValue = intValue
    }
}

struct SurrealValueDecoder: Decoder {
    let value: SurrealValue
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw Self.mismatch([String: SurrealValue].self, value, codingPath)
        }
        return KeyedDecodingContainer(KeyedContainer<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        switch value {
        case .array(let values), .set(let values):
            return UnkeyedContainer(values: values, codingPath: codingPath)
        default:
            throw Self.mismatch([SurrealValue].self, value, codingPath)
        }
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleContainer(value: value, codingPath: codingPath)
    }

    // MARK: Unboxing

    static func unbox<T: Decodable>(_ value: SurrealValue, as type: T.Type, codingPath: [any CodingKey]) throws -> T {
        if let special = try unboxSpecial(value, as: type, codingPath: codingPath) {
            return special
        }
        return try T(from: SurrealValueDecoder(value: value, codingPath: codingPath))
    }

    /// Types that map onto a SurrealDB type rather than onto their own
    /// Codable representation.
    private static func unboxSpecial<T>(_ value: SurrealValue, as type: T.Type, codingPath: [any CodingKey]) throws -> T? {
        if type == SurrealValue.self {
            return value as? T
        }
        if type == Date.self {
            return try unboxDate(value, codingPath) as? T
        }
        if type == UUID.self {
            return try unboxUUID(value, codingPath) as? T
        }
        if type == Data.self {
            return try unboxData(value, codingPath) as? T
        }
        if type == Decimal.self {
            return try unboxDecimal(value, codingPath) as? T
        }
        if type == SurrealRecordID.self {
            return try unboxRecordID(value, codingPath) as? T
        }
        if type == URL.self {
            let string = try unboxString(value, codingPath)
            guard let url = URL(string: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid URL: \(string)"))
            }
            return url as? T
        }
        return nil
    }

    static func unboxString(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> String {
        switch value {
        case .string(let string):
            return string
        case .recordID(let id):
            return id.rawValue
        case .uuid(let uuid):
            return uuid.uuidString.lowercased()
        case .duration(let text), .decimal(let text), .table(let text):
            return text
        case .datetime(let date):
            return SurrealValue.iso8601Fractional(date)
        default:
            throw mismatch(String.self, value, codingPath)
        }
    }

    static func unboxBool(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw mismatch(Bool.self, value, codingPath)
        }
        return bool
    }

    static func unboxInteger<T: FixedWidthInteger>(_ value: SurrealValue, as type: T.Type, _ codingPath: [any CodingKey]) throws -> T {
        let result: T?
        switch value {
        case .int(let int):
            result = T(exactly: int)
        case .double(let double):
            result = T(exactly: double)
        case .decimal(let text):
            result = T(text)
        default:
            throw mismatch(T.self, value, codingPath)
        }
        guard let result else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "\(value) does not fit in \(T.self)."
            ))
        }
        return result
    }

    static func unboxDouble(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> Double {
        switch value {
        case .double(let double):
            return double
        case .int(let int):
            return Double(int)
        case .decimal(let text):
            guard let double = Double(text) else { throw mismatch(Double.self, value, codingPath) }
            return double
        default:
            throw mismatch(Double.self, value, codingPath)
        }
    }

    /// A finite double too large for `Float` would silently become infinity.
    static func unboxFloat(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> Float {
        let double = try unboxDouble(value, codingPath)
        let float = Float(double)
        guard float.isFinite || !double.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(double) is out of range for Float."))
        }
        return float
    }

    private static func unboxDate(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> Date {
        switch value {
        case .datetime(let date):
            return date
        case .string(let text):
            if let date = SurrealValue.parseISO8601(text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid datetime: \(text)"))
        default:
            throw mismatch(Date.self, value, codingPath)
        }
    }

    private static func unboxUUID(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> UUID {
        switch value {
        case .uuid(let uuid):
            return uuid
        case .string(let text):
            if let uuid = UUID(uuidString: text) {
                return uuid
            }
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid UUID: \(text)"))
        default:
            throw mismatch(UUID.self, value, codingPath)
        }
    }

    private static func unboxData(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> Data {
        switch value {
        case .bytes(let data):
            return data
        case .string(let text):
            if let data = Data(base64Encoded: text) {
                return data
            }
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid base64 bytes."))
        default:
            throw mismatch(Data.self, value, codingPath)
        }
    }

    private static func unboxDecimal(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> Decimal {
        switch value {
        case .decimal(let text), .string(let text):
            // Decimal(string:) accepts a numeric prefix ("12.5oops" is 12.5),
            // so check the whole text first.
            if SurrealValue.isDecimalText(text),
               let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN {
                return decimal
            }
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid decimal: \(text)"))
        case .int(let int):
            return Decimal(int)
        case .double(let double):
            // Decimal(Double) traps for infinities on Linux and gives NaN for
            // values beyond its range.
            guard double.isFinite else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(double) can't be a Decimal."))
            }
            let decimal = Decimal(double)
            guard !decimal.isNaN else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(double) is out of range for Decimal."))
            }
            return decimal
        default:
            throw mismatch(Decimal.self, value, codingPath)
        }
    }

    private static func unboxRecordID(_ value: SurrealValue, _ codingPath: [any CodingKey]) throws -> SurrealRecordID {
        switch value {
        case .recordID(let id):
            return id
        case .object(let object):
            // The synthesized Codable shape, for values that came through JSON.
            guard case .string(let table)? = object["table"], let id = object["id"] else {
                throw mismatch(SurrealRecordID.self, value, codingPath)
            }
            return SurrealRecordID(table: table, id: id)
        default:
            throw mismatch(SurrealRecordID.self, value, codingPath)
        }
    }

    static func mismatch(_ type: Any.Type, _ value: SurrealValue, _ codingPath: [any CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(type, .init(
            codingPath: codingPath,
            debugDescription: "Expected \(type), found \(value.kindName)."
        ))
    }

    // MARK: Containers

    private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let object: [String: SurrealValue]
        let codingPath: [any CodingKey]

        var allKeys: [Key] { object.keys.compactMap(Key.init(stringValue:)) }

        func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

        private func value(for key: Key) throws -> SurrealValue {
            guard let value = object[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(
                    codingPath: codingPath,
                    debugDescription: "No value for key \"\(key.stringValue)\"."
                ))
            }
            return value
        }

        /// Throws `keyNotFound` for a missing key, as `JSONDecoder` does;
        /// `decodeIfPresent` checks `contains` first.
        func decodeNil(forKey key: Key) throws -> Bool {
            switch try value(for: key) {
            case .null, .none:
                return true
            default:
                return false
            }
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try SurrealValueDecoder.unbox(value(for: key), as: T.self, codingPath: codingPath + [key])
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            try SurrealValueDecoder(value: value(for: key), codingPath: codingPath + [key]).container(keyedBy: NestedKey.self)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try SurrealValueDecoder(value: value(for: key), codingPath: codingPath + [key]).unkeyedContainer()
        }

        func superDecoder() throws -> any Decoder {
            SurrealValueDecoder(value: object["super"] ?? .none, codingPath: codingPath + [SurrealCodingKey(stringValue: "super")])
        }

        func superDecoder(forKey key: Key) throws -> any Decoder {
            SurrealValueDecoder(value: object[key.stringValue] ?? .none, codingPath: codingPath + [key])
        }
    }

    private struct UnkeyedContainer: UnkeyedDecodingContainer {
        let values: [SurrealValue]
        let codingPath: [any CodingKey]
        var currentIndex = 0

        init(values: [SurrealValue], codingPath: [any CodingKey]) {
            self.values = values
            self.codingPath = codingPath
        }

        var count: Int? { values.count }
        var isAtEnd: Bool { currentIndex >= values.count }

        private var currentKey: any CodingKey { SurrealCodingKey(intValue: currentIndex) }

        private mutating func next() throws -> SurrealValue {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(SurrealValue.self, .init(
                    codingPath: codingPath + [currentKey],
                    debugDescription: "Unkeyed container is at end."
                ))
            }
            defer { currentIndex += 1 }
            return values[currentIndex]
        }

        mutating func decodeNil() throws -> Bool {
            guard !isAtEnd else { return false }
            switch values[currentIndex] {
            case .null, .none:
                currentIndex += 1
                return true
            default:
                return false
            }
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let path = codingPath + [currentKey]
            return try SurrealValueDecoder.unbox(next(), as: T.self, codingPath: path)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
            let path = codingPath + [currentKey]
            return try SurrealValueDecoder(value: next(), codingPath: path).container(keyedBy: NestedKey.self)
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            let path = codingPath + [currentKey]
            return try SurrealValueDecoder(value: next(), codingPath: path).unkeyedContainer()
        }

        mutating func superDecoder() throws -> any Decoder {
            let path = codingPath + [currentKey]
            return SurrealValueDecoder(value: try next(), codingPath: path)
        }
    }

    private struct SingleContainer: SingleValueDecodingContainer {
        let value: SurrealValue
        let codingPath: [any CodingKey]

        func decodeNil() -> Bool {
            value == .null || value == .none
        }

        func decode(_ type: Bool.Type) throws -> Bool { try unboxBool(value, codingPath) }
        func decode(_ type: String.Type) throws -> String { try unboxString(value, codingPath) }
        func decode(_ type: Double.Type) throws -> Double { try unboxDouble(value, codingPath) }
        func decode(_ type: Float.Type) throws -> Float { try unboxFloat(value, codingPath) }
        func decode(_ type: Int.Type) throws -> Int { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: Int8.Type) throws -> Int8 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: Int16.Type) throws -> Int16 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: Int32.Type) throws -> Int32 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: Int64.Type) throws -> Int64 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: UInt.Type) throws -> UInt { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try unboxInteger(value, as: type, codingPath) }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try unboxInteger(value, as: type, codingPath) }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try SurrealValueDecoder.unbox(value, as: T.self, codingPath: codingPath)
        }
    }
}

// MARK: - Encoding

/// Builds a `SurrealValue` tree. Containers write into shared boxes so nested
/// containers can be filled after they're handed out, as Codable requires.
final class SurrealValueEncoder: Encoder {
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    fileprivate var storage: Box?

    init(codingPath: [any CodingKey]) {
        self.codingPath = codingPath
    }

    static func box<T: Encodable>(_ value: T, codingPath: [any CodingKey]) throws -> SurrealValue {
        if let special = boxSpecial(value) {
            return special
        }
        let encoder = SurrealValueEncoder(codingPath: codingPath)
        try value.encode(to: encoder)
        // A type that encodes nothing at all becomes an empty object, as
        // JSONEncoder does.
        return encoder.storage?.resolve() ?? .object([:])
    }

    private static func boxSpecial<T: Encodable>(_ value: T) -> SurrealValue? {
        switch value {
        case let value as SurrealValue:
            return value
        case let value as Date:
            return .datetime(value)
        case let value as UUID:
            return .uuid(value)
        case let value as Data:
            return .bytes(value)
        case let value as Decimal:
            return .decimal(NSDecimalNumber(decimal: value).stringValue)
        case let value as SurrealRecordID:
            return .recordID(value)
        case let value as URL:
            return .string(value.absoluteString)
        default:
            return nil
        }
    }

    fileprivate final class Box {
        enum Kind {
            case single(SurrealValue)
            case object([String: Box])
            case array([Box])
            case value(SurrealValue)
        }

        var kind: Kind

        init(_ kind: Kind) {
            self.kind = kind
        }

        func resolve() -> SurrealValue {
            switch kind {
            case .single(let value), .value(let value):
                return value
            case .object(let entries):
                return .object(entries.mapValues { $0.resolve() })
            case .array(let items):
                return .array(items.map { $0.resolve() })
            }
        }
    }

    fileprivate func objectBox() -> Box {
        if let storage, case .object = storage.kind {
            return storage
        }
        let box = Box(.object([:]))
        storage = box
        return box
    }

    fileprivate func arrayBox() -> Box {
        if let storage, case .array = storage.kind {
            return storage
        }
        let box = Box(.array([]))
        storage = box
        return box
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedContainer<Key>(box: objectBox(), codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        UnkeyedContainer(box: arrayBox(), codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleContainer(encoder: self)
    }

    fileprivate static func boxInteger<T: FixedWidthInteger>(_ value: T) -> SurrealValue {
        if let int = Int64(exactly: value) {
            return .int(int)
        }
        // Only UInt64 values above Int64.max get here.
        return .decimal(String(value))
    }

    // MARK: Containers

    private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let box: Box
        let codingPath: [any CodingKey]

        private func set(_ value: Box, for key: Key) {
            set(value, named: key.stringValue)
        }

        private func set(_ value: Box, named name: String) {
            guard case .object(var entries) = box.kind else { return }
            entries[name] = value
            box.kind = .object(entries)
        }

        mutating func encodeNil(forKey key: Key) throws {
            set(Box(.value(.null)), for: key)
        }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            set(Box(.value(try SurrealValueEncoder.box(value, codingPath: codingPath + [key]))), for: key)
        }

        mutating func encode(_ value: Bool, forKey key: Key) throws { set(Box(.value(.bool(value))), for: key) }
        mutating func encode(_ value: String, forKey key: Key) throws { set(Box(.value(.string(value))), for: key) }
        mutating func encode(_ value: Double, forKey key: Key) throws { set(Box(.value(.double(value))), for: key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { set(Box(.value(.double(Double(value)))), for: key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { set(Box(.value(boxInteger(value))), for: key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { set(Box(.value(boxInteger(value))), for: key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { set(Box(.value(boxInteger(value))), for: key) }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            let nested = Box(.object([:]))
            set(nested, for: key)
            return KeyedEncodingContainer(KeyedContainer<NestedKey>(box: nested, codingPath: codingPath + [key]))
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            let nested = Box(.array([]))
            set(nested, for: key)
            return UnkeyedContainer(box: nested, codingPath: codingPath + [key])
        }

        /// Uses its own `"super"` key: the model's `CodingKeys` usually has no
        /// such case, so `Key(stringValue: "super")` can't be relied on.
        mutating func superEncoder() -> any Encoder {
            superEncoder(named: "super", key: SurrealCodingKey(stringValue: "super"))
        }

        mutating func superEncoder(forKey key: Key) -> any Encoder {
            superEncoder(named: key.stringValue, key: key)
        }

        private mutating func superEncoder(named name: String, key: any CodingKey) -> any Encoder {
            let encoder = SurrealValueEncoder(codingPath: codingPath + [key])
            let placeholder = Box(.value(.object([:])))
            set(placeholder, named: name)
            // Resolved lazily: the super encoder is filled after this returns.
            encoder.storage = placeholder
            return ReferencingEncoder(encoder: encoder, slot: placeholder)
        }
    }

    private struct UnkeyedContainer: UnkeyedEncodingContainer {
        let box: Box
        let codingPath: [any CodingKey]

        var count: Int {
            guard case .array(let items) = box.kind else { return 0 }
            return items.count
        }

        private func append(_ value: Box) {
            guard case .array(var items) = box.kind else { return }
            items.append(value)
            box.kind = .array(items)
        }

        private var nextKey: any CodingKey { SurrealCodingKey(intValue: count) }

        mutating func encodeNil() throws { append(Box(.value(.null))) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            append(Box(.value(try SurrealValueEncoder.box(value, codingPath: codingPath + [nextKey]))))
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            let path = codingPath + [nextKey]
            let nested = Box(.object([:]))
            append(nested)
            return KeyedEncodingContainer(KeyedContainer<NestedKey>(box: nested, codingPath: path))
        }

        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            let path = codingPath + [nextKey]
            let nested = Box(.array([]))
            append(nested)
            return UnkeyedContainer(box: nested, codingPath: path)
        }

        mutating func superEncoder() -> any Encoder {
            let encoder = SurrealValueEncoder(codingPath: codingPath + [nextKey])
            let placeholder = Box(.value(.object([:])))
            append(placeholder)
            encoder.storage = placeholder
            return ReferencingEncoder(encoder: encoder, slot: placeholder)
        }
    }

    private struct SingleContainer: SingleValueEncodingContainer {
        let encoder: SurrealValueEncoder
        var codingPath: [any CodingKey] { encoder.codingPath }

        private func store(_ value: SurrealValue) {
            if let storage = encoder.storage {
                storage.kind = .single(value)
            } else {
                encoder.storage = Box(.single(value))
            }
        }

        mutating func encodeNil() throws { store(.null) }
        mutating func encode(_ value: Bool) throws { store(.bool(value)) }
        mutating func encode(_ value: String) throws { store(.string(value)) }
        mutating func encode(_ value: Double) throws { store(.double(value)) }
        mutating func encode(_ value: Float) throws { store(.double(Double(value))) }
        mutating func encode(_ value: Int) throws { store(boxInteger(value)) }
        mutating func encode(_ value: Int8) throws { store(boxInteger(value)) }
        mutating func encode(_ value: Int16) throws { store(boxInteger(value)) }
        mutating func encode(_ value: Int32) throws { store(boxInteger(value)) }
        mutating func encode(_ value: Int64) throws { store(boxInteger(value)) }
        mutating func encode(_ value: UInt) throws { store(boxInteger(value)) }
        mutating func encode(_ value: UInt8) throws { store(boxInteger(value)) }
        mutating func encode(_ value: UInt16) throws { store(boxInteger(value)) }
        mutating func encode(_ value: UInt32) throws { store(boxInteger(value)) }
        mutating func encode(_ value: UInt64) throws { store(boxInteger(value)) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            store(try SurrealValueEncoder.box(value, codingPath: codingPath))
        }
    }

    /// A super encoder whose result lands in a slot of its parent container
    /// once the subclass has finished encoding into it.
    private final class ReferencingEncoder: Encoder {
        let encoder: SurrealValueEncoder
        let slot: Box

        init(encoder: SurrealValueEncoder, slot: Box) {
            self.encoder = encoder
            self.slot = slot
        }

        var codingPath: [any CodingKey] { encoder.codingPath }
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            slot.kind = .object([:])
            return encoder.container(keyedBy: type)
        }

        func unkeyedContainer() -> any UnkeyedEncodingContainer {
            slot.kind = .array([])
            return encoder.unkeyedContainer()
        }

        func singleValueContainer() -> any SingleValueEncodingContainer {
            encoder.singleValueContainer()
        }
    }
}

// MARK: - Helpers

extension SurrealValue {
    /// A short name for the value's type, for error messages.
    var kindName: String {
        switch self {
        case .none: "NONE"
        case .null: "NULL"
        case .bool: "bool"
        case .int: "int"
        case .double: "float"
        case .string: "string"
        case .bytes: "bytes"
        case .datetime: "datetime"
        case .uuid: "uuid"
        case .decimal: "decimal"
        case .duration: "duration"
        case .table: "table"
        case .recordID: "record id"
        case .range: "range"
        case .set: "set"
        case .geometry: "geometry"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Parses RFC 3339 with or without fractional seconds.
    package static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }
}
