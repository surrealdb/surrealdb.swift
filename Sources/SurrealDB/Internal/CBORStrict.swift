import Foundation

/// Checks the CBOR decoder can't make on its own: PotentCBOR keeps the last
/// of two equal map keys, so duplicates are found by walking the raw bytes.
enum CBORStructure {
    /// Throws if any map in `data` repeats a text key. Other malformed input
    /// is left to the decoder.
    static func checkDuplicateKeys(_ data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        _ = try reader.item(depth: 0)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        static let maxDepth = 512

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw malformed }
            defer { offset += 1 }
            return bytes[offset]
        }

        var malformed: SurrealError { SurrealError.invalidResponse("Malformed CBOR.") }

        /// The argument of an initial byte, or `nil` for an indefinite length.
        mutating func argument(_ info: UInt8) throws -> UInt64? {
            switch info {
            case 0..<24:
                return UInt64(info)
            case 24, 25, 26, 27:
                var value: UInt64 = 0
                for _ in 0..<(1 << (info - 24)) {
                    value = value << 8 | UInt64(try byte())
                }
                return value
            case 31:
                return nil
            default:
                throw malformed
            }
        }

        mutating func take(_ count: UInt64) throws -> ArraySlice<UInt8> {
            guard count <= UInt64(bytes.count - offset) else { throw malformed }
            defer { offset += Int(count) }
            return bytes[offset..<offset + Int(count)]
        }

        mutating func atBreak() -> Bool {
            guard offset < bytes.count, bytes[offset] == 0xFF else { return false }
            offset += 1
            return true
        }

        /// Skips one item. For a text string, returns its bytes (chunks
        /// joined), so a map can compare its keys.
        mutating func item(depth: Int) throws -> [UInt8]? {
            guard depth < Self.maxDepth else { throw SurrealError.invalidResponse("CBOR nested too deeply.") }
            let initial = try byte()
            let major = initial >> 5
            let length = try argument(initial & 0x1F)
            switch major {
            case 0, 1:
                guard length != nil else { throw malformed }
                return nil
            case 2, 3:
                guard let length else {
                    var joined: [UInt8] = []
                    while !atBreak() {
                        // Each chunk is a definite string of the same major type.
                        let chunk = try byte()
                        guard chunk >> 5 == major, let size = try argument(chunk & 0x1F) else { throw malformed }
                        joined += try take(size)
                    }
                    return major == 3 ? joined : nil
                }
                let content = try take(length)
                return major == 3 ? Array(content) : nil
            case 4:
                if let length {
                    for _ in 0..<length { _ = try item(depth: depth + 1) }
                } else {
                    while !atBreak() { _ = try item(depth: depth + 1) }
                }
                return nil
            case 5:
                var keys = Set<[UInt8]>()
                func pair() throws {
                    if let key = try item(depth: depth + 1), !keys.insert(key).inserted {
                        throw SurrealError.invalidResponse("CBOR map repeats the key \"\(String(decoding: key, as: UTF8.self))\".")
                    }
                    _ = try item(depth: depth + 1)
                }
                if let length {
                    for _ in 0..<length { try pair() }
                } else {
                    while !atBreak() { try pair() }
                }
                return nil
            case 6:
                guard length != nil else { throw malformed }
                _ = try item(depth: depth + 1)
                return nil
            default:
                // Simple values and floats; their bytes were read with the
                // argument. A bare break is malformed.
                guard length != nil else { throw malformed }
                return nil
            }
        }
    }
}

enum DecimalText {
    /// The largest decimal mantissa, 2^96 - 1.
    private static let maxMantissa = "79228162514264337593543950335"

    /// Whether `text` (already `isDecimalText`) is a decimal the server can
    /// hold exactly: a mantissa of at most 96 bits and at most 28
    /// fractional digits.
    static func fits(_ text: String) -> Bool {
        var body = Substring(text)
        if body.hasPrefix("-") { body = body.dropFirst() }
        var exponent = 0
        if let e = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let value = Int(body[body.index(after: e)...]) else { return false }
            exponent = value
            body = body[..<e]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? parts[1] : ""
        var digits = String(parts[0] + fraction)
        var scale = fraction.count - exponent
        if scale < 0 {
            digits += String(repeating: "0", count: -scale)
            scale = 0
        }
        guard scale <= 28 else { return false }
        let mantissa = digits.drop { $0 == "0" }
        return mantissa.count < maxMantissa.count
            || (mantissa.count == maxMantissa.count && mantissa <= Substring(maxMantissa))
    }
}

/// Parses a record id in SurrealQL text (`person:alice`, `⟨user profile⟩:1`,
/// `person:[1, 'x']`), the string form of tag 8. The server accepts it,
/// though it never sends it.
struct RecordIDText {
    private let scalars: [Unicode.Scalar]
    private var offset = 0

    static func parse(_ text: String) throws -> SurrealRecordID {
        var parser = RecordIDText(scalars: Array(text.unicodeScalars))
        let table = try parser.identifier()
        try parser.expect(":")
        let key = try parser.key()
        guard parser.offset == parser.scalars.count else { throw parser.failure }
        return SurrealRecordID(table: table, id: key)
    }

    private init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    private var failure: SurrealError {
        SurrealError.invalidResponse("Expected a record id in SurrealQL (tag 8).")
    }

    private var current: Unicode.Scalar? {
        offset < scalars.count ? scalars[offset] : nil
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard current == scalar else { throw failure }
        offset += 1
    }

    private mutating func skipWhitespace() {
        while let scalar = current, scalar.properties.isWhitespace { offset += 1 }
    }

    private static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
    }

    /// A bare identifier, or one escaped in `⟨…⟩` or backticks.
    private mutating func identifier() throws -> String {
        switch current {
        case "⟨":
            return try delimited(close: "⟩")
        case "`":
            return try delimited(close: "`")
        default:
            let start = offset
            while let scalar = current, Self.isIdentifier(scalar) { offset += 1 }
            guard offset > start else { throw failure }
            return String(String.UnicodeScalarView(scalars[start..<offset]))
        }
    }

    private mutating func delimited(close: Unicode.Scalar) throws -> String {
        offset += 1
        var text = String.UnicodeScalarView()
        while let scalar = current {
            offset += 1
            if scalar == close { return String(text) }
            if scalar == "\\", let next = current {
                offset += 1
                text.append(next)
            } else {
                text.append(scalar)
            }
        }
        throw failure
    }

    private mutating func key() throws -> SurrealValue {
        switch current {
        case "[", "{":
            return try value()
        case "u" where offset + 1 < scalars.count && (scalars[offset + 1] == "'" || scalars[offset + 1] == "\""):
            return try value()
        case "⟨", "`":
            return .string(try identifier())
        default:
            let text = try identifier()
            // Digits that fit i64 are a number; past that they're a name.
            if text.allSatisfy(\.isASCIIDigit), let int = Int64(text) {
                return .int(int)
            }
            return .string(text)
        }
    }

    private mutating func negativeOrNumber() throws -> SurrealValue {
        let start = offset
        if current == "-" { offset += 1 }
        var isFloat = false
        while let scalar = current, scalar.isASCII, CharacterSet.decimalDigits.contains(scalar) || scalar == "." || scalar == "e" || scalar == "E" {
            if scalar == "." || scalar == "e" || scalar == "E" { isFloat = true }
            offset += 1
        }
        let text = String(String.UnicodeScalarView(scalars[start..<offset]))
        if current == "f" {
            offset += 1
            isFloat = true
        }
        if isFloat, let double = Double(text) { return .double(double) }
        if let int = Int64(text) { return .int(int) }
        throw failure
    }

    /// A value inside an array or object key.
    private mutating func value() throws -> SurrealValue {
        skipWhitespace()
        guard let scalar = current else { throw failure }
        switch scalar {
        case "[":
            offset += 1
            var values: [SurrealValue] = []
            skipWhitespace()
            if current == "]" {
                offset += 1
                return .array(values)
            }
            while true {
                values.append(try value())
                skipWhitespace()
                if current == "," {
                    offset += 1
                    skipWhitespace()
                    if current == "]" { offset += 1; return .array(values) }
                    continue
                }
                try expect("]")
                return .array(values)
            }
        case "{":
            offset += 1
            var fields: [String: SurrealValue] = [:]
            skipWhitespace()
            if current == "}" {
                offset += 1
                return .object(fields)
            }
            while true {
                skipWhitespace()
                let name: String
                if current == "'" || current == "\"" {
                    name = try quoted()
                } else {
                    name = try identifier()
                }
                skipWhitespace()
                try expect(":")
                fields[name] = try value()
                skipWhitespace()
                if current == "," {
                    offset += 1
                    skipWhitespace()
                    if current == "}" { offset += 1; return .object(fields) }
                    continue
                }
                try expect("}")
                return .object(fields)
            }
        case "'", "\"":
            return .string(try quoted())
        case "u" where offset + 1 < scalars.count && (scalars[offset + 1] == "'" || scalars[offset + 1] == "\""):
            offset += 1
            guard let uuid = UUID(uuidString: try quoted()) else { throw failure }
            return .uuid(uuid)
        case "-", "0"..."9":
            return try negativeOrNumber()
        default:
            let word = try identifier()
            switch word.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "none": return .none
            default: throw failure
            }
        }
    }

    /// A quoted string with SurrealQL's escapes.
    private mutating func quoted() throws -> String {
        guard let quote = current else { throw failure }
        offset += 1
        var text = String.UnicodeScalarView()
        while let scalar = current {
            offset += 1
            if scalar == quote { return String(text) }
            guard scalar == "\\" else {
                text.append(scalar)
                continue
            }
            guard let escape = current else { throw failure }
            offset += 1
            switch escape {
            case "\\", "'", "\"", "/", "`", "⟩": text.append(escape)
            case "b": text.append("\u{08}")
            case "f": text.append("\u{0C}")
            case "n": text.append("\n")
            case "r": text.append("\r")
            case "t": text.append("\t")
            case "0": text.append("\0")
            case "u": text.append(try unicodeEscape())
            default: throw failure
            }
        }
        throw failure
    }

    /// `\uXXXX` or `\u{X…}`, after the `u`. A lone surrogate isn't a
    /// character, so it fails.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        var hex = ""
        if current == "{" {
            offset += 1
            while let scalar = current, scalar != "}" {
                hex.unicodeScalars.append(scalar)
                offset += 1
            }
            try expect("}")
            guard (1...6).contains(hex.count) else { throw failure }
        } else {
            for _ in 0..<4 {
                guard let scalar = current else { throw failure }
                hex.unicodeScalars.append(scalar)
                offset += 1
            }
        }
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { throw failure }
        return scalar
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
