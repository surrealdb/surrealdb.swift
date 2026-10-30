import Foundation

/// A JSON value that keeps integers apart from floats and holds integers as
/// their exact text, so `9223372036854775807` survives a round trip.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(String)
    case float(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.atEnd else { throw JSONParseError("trailing characters at offset \(parser.offset)") }
        return value
    }

    /// Compact JSON text. Object keys are sorted so the output is stable.
    public var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .integer(let text):
            out += text
        case .float(let value):
            // JSON has no NaN or infinity; typed JSON spells those as strings.
            out += value.isFinite ? "\(value)" : "null"
        case .string(let value):
            Self.writeString(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                fields[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

public struct JSONParseError: Error, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = "Invalid JSON: \(description)"
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var atEnd: Bool { offset >= bytes.count }

    mutating func skipWhitespace() {
        while !atEnd, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[offset]) {
            offset += 1
        }
    }

    mutating func value() throws -> JSONValue {
        guard !atEnd else { throw JSONParseError("unexpected end") }
        switch bytes[offset] {
        case UInt8(ascii: "{"):
            return try object()
        case UInt8(ascii: "["):
            return try array()
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null")
            return .null
        default:
            return try number()
        }
    }

    mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard offset + expected.count <= bytes.count, Array(bytes[offset..<offset + expected.count]) == expected else {
            throw JSONParseError("expected \(word) at offset \(offset)")
        }
        offset += expected.count
    }

    mutating func object() throws -> JSONValue {
        offset += 1
        var fields: [String: JSONValue] = [:]
        skipWhitespace()
        if !atEnd, bytes[offset] == UInt8(ascii: "}") {
            offset += 1
            return .object(fields)
        }
        while true {
            skipWhitespace()
            guard !atEnd, bytes[offset] == UInt8(ascii: "\"") else { throw JSONParseError("expected a key at offset \(offset)") }
            let key = try string()
            skipWhitespace()
            guard !atEnd, bytes[offset] == UInt8(ascii: ":") else { throw JSONParseError("expected : at offset \(offset)") }
            offset += 1
            skipWhitespace()
            fields[key] = try value()
            skipWhitespace()
            guard !atEnd else { throw JSONParseError("unterminated object") }
            if bytes[offset] == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            guard bytes[offset] == UInt8(ascii: "}") else { throw JSONParseError("expected , or } at offset \(offset)") }
            offset += 1
            return .object(fields)
        }
    }

    mutating func array() throws -> JSONValue {
        offset += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if !atEnd, bytes[offset] == UInt8(ascii: "]") {
            offset += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            values.append(try value())
            skipWhitespace()
            guard !atEnd else { throw JSONParseError("unterminated array") }
            if bytes[offset] == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            guard bytes[offset] == UInt8(ascii: "]") else { throw JSONParseError("expected , or ] at offset \(offset)") }
            offset += 1
            return .array(values)
        }
    }

    mutating func string() throws -> String {
        offset += 1
        var scalars = String.UnicodeScalarView()
        var run: [UInt8] = []
        func flush() {
            scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
            run.removeAll()
        }
        while true {
            guard !atEnd else { throw JSONParseError("unterminated string") }
            let byte = bytes[offset]
            offset += 1
            if byte == UInt8(ascii: "\"") {
                flush()
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else {
                run.append(byte)
                continue
            }
            flush()
            guard !atEnd else { throw JSONParseError("unterminated escape") }
            let escape = bytes[offset]
            offset += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code) {
                    // A surrogate pair: the low half must follow.
                    try literal("\\u")
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low) else { throw JSONParseError("bad surrogate pair") }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { throw JSONParseError("bad \\u escape") }
                scalars.append(scalar)
            default:
                throw JSONParseError("bad escape at offset \(offset)")
            }
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard offset + 4 <= bytes.count,
              let code = UInt32(String(decoding: bytes[offset..<offset + 4], as: UTF8.self), radix: 16)
        else {
            throw JSONParseError("bad \\u escape at offset \(offset)")
        }
        offset += 4
        return code
    }

    mutating func number() throws -> JSONValue {
        let start = offset
        var isFloat = false
        while !atEnd {
            let byte = bytes[offset]
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") {
                offset += 1
            } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                isFloat = true
                offset += 1
            } else {
                break
            }
        }
        let text = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard !text.isEmpty else { throw JSONParseError("unexpected character at offset \(start)") }
        if isFloat {
            guard let value = Double(text) else { throw JSONParseError("bad number \(text)") }
            return .float(value)
        }
        guard text.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else {
            throw JSONParseError("bad number \(text)")
        }
        return .integer(text)
    }
}
