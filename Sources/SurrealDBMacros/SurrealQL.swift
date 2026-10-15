import Foundation

/// Escaping helpers for building SurrealQL text.
///
/// The SDK sends values as bound variables wherever it can, so these are only
/// needed for the parts of a statement that can't be bound: table and field
/// names. They're public for callers writing their own SurrealQL.
public enum SurrealQL {
    /// Escapes an identifier (a table or field name) with backticks, so it can
    /// never be read as a keyword, a value, or the end of the identifier.
    ///
    /// Always escapes: names like `value`, `none`, `true` or `select` parse as
    /// something else when left bare.
    public static func escapeIdent(_ name: String) -> String {
        "`" + escapeContents(name, delimiter: "`") + "`"
    }

    /// Escapes a dotted field path one segment at a time, so `address.city`
    /// becomes `` `address`.`city` ``.
    public static func escapeFieldPath(_ path: String) -> String {
        path.split(separator: ".", omittingEmptySubsequences: false)
            .map { escapeIdent(String($0)) }
            .joined(separator: ".")
    }

    /// Quotes a string as a double-quoted SurrealQL string literal.
    public static func quote(_ value: String) -> String {
        "\"" + escapeContents(value, delimiter: "\"") + "\""
    }

    /// Renders an identifier the way the server does: bare when it's a plain
    /// identifier, backtick-escaped otherwise. Used for display (e.g. record
    /// ids) where readability matters; generated statements use
    /// ``escapeIdent(_:)``.
    static func displayIdent(_ name: String) -> String {
        isPlainIdent(name) ? name : escapeIdent(name)
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`.
    static func isPlainIdent(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard first == "_" || isASCIILetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || isASCIIDigit($0) }
    }

    private static func escapeContents(_ value: String, delimiter: Character) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == delimiter {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// `$name`, cast to the value's SurrealDB type where the JSON wire
    /// format would send it as a plain string (datetimes, UUIDs, decimals,
    /// durations, record ids). The cast is a no-op over CBOR. NONE and bytes
    /// can't be bound portably (JSON sends NULL and base64 text), so write
    /// those inline with `sqlLiteral`.
    public static func typedParameter(_ name: String, for value: SurrealValue) -> String {
        switch value {
        case .datetime: return "<datetime>$\(name)"
        case .uuid: return "<uuid>$\(name)"
        case .decimal: return "<decimal>$\(name)"
        case .duration: return "<duration>$\(name)"
        case .recordID: return "<record>$\(name)"
        default: return "$\(name)"
        }
    }

    /// Replaces the parameter `$name` with `$newName` in SurrealQL text,
    /// leaving longer names that start with `name`, and anything inside
    /// strings, quoted identifiers and comments, alone.
    public static func renameParameter(_ name: String, to newName: String, in sql: String) -> String {
        let chars = Array(sql)
        let target = Array(name)
        var out = ""
        var i = 0
        func isIdentChar(_ c: Character) -> Bool {
            c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
        }
        /// Copies a quoted run that starts at `i` and ends at `close`,
        /// honouring backslash escapes.
        func copyQuoted(close: Character) {
            out.append(chars[i])
            i += 1
            while i < chars.count {
                let c = chars[i]
                out.append(c)
                i += 1
                if c == "\\", i < chars.count {
                    out.append(chars[i])
                    i += 1
                } else if c == close {
                    return
                }
            }
        }
        /// Copies from `i` up to and including `end`, or to the end.
        func copyThrough(_ end: [Character]) {
            while i < chars.count {
                if Array(chars[i..<min(i + end.count, chars.count)]) == end {
                    out.append(contentsOf: end)
                    i += end.count
                    return
                }
                out.append(chars[i])
                i += 1
            }
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "'", "\"", "`":
                copyQuoted(close: c)
            case "⟨":
                copyQuoted(close: "⟩")
            case "#":
                copyThrough(["\n"])
            case "-" where next == "-", "/" where next == "/":
                copyThrough(["\n"])
            case "/" where next == "*":
                copyThrough(["*", "/"])
            case "$":
                let start = i + 1
                let end = start + target.count
                if end <= chars.count, Array(chars[start..<end]) == target,
                   end == chars.count || !isIdentChar(chars[end]) {
                    out.append("$" + newName)
                    i = end
                } else {
                    out.append(c)
                    i += 1
                }
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }
}

/// Hands out binding names for predicate values. Names only need to be unique
/// within a statement, but predicates are built independently and combined
/// later, so a process-wide counter is the simplest way to never collide.
enum PredicateBindingNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    static func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        return "_pv\(counter)"
    }

}
