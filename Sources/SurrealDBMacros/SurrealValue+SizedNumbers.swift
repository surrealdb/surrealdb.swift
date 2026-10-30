import Foundation

/// One of SurrealDB 4.0's fixed-width numbers: `i8`, `u8`, `i16`, `u16`,
/// `i32`, `u32`, `u64`, `f16` or `f32`.
///
/// The width is part of the value. Over `cbor.2` (negotiated with a 4.0
/// server) it travels in its own CBOR tag, so a `u8` comes back as a `u8`.
/// Over plain `cbor` and JSON the server widens these, and so does the client:
/// the integers become `int` (or, for a `u64` above `Int64.max`, a decimal)
/// and the floats become `float`. See ``widened``.
///
/// The server compares numbers by value whatever their width (`5u8 == 5`),
/// but here `.sized(.u8(5))` and `.int(5)` are different values, because they
/// decode from different bytes.
public enum SurrealSizedNumber: Sendable, Hashable {
    case i8(Int8)
    case u8(UInt8)
    case i16(Int16)
    case u16(UInt16)
    case i32(Int32)
    case u32(UInt32)
    case u64(UInt64)
    case f16(SurrealFloat16)
    case f32(Float)

    /// The SurrealQL name of the kind: `"i8"`, `"u64"`, `"f32"` and so on.
    public var kindName: String {
        switch self {
        case .i8: "i8"
        case .u8: "u8"
        case .i16: "i16"
        case .u16: "u16"
        case .i32: "i32"
        case .u32: "u32"
        case .u64: "u64"
        case .f16: "f16"
        case .f32: "f32"
        }
    }

    /// The value as a server before 4.0, or a plain `cbor` connection,
    /// carries it: `.int` for the integers, `.decimal` for a `u64` above
    /// `Int64.max`, and `.double` for the floats.
    public var widened: SurrealValue {
        switch self {
        case .i8(let value): .int(Int64(value))
        case .u8(let value): .int(Int64(value))
        case .i16(let value): .int(Int64(value))
        case .u16(let value): .int(Int64(value))
        case .i32(let value): .int(Int64(value))
        case .u32(let value): .int(Int64(value))
        case .u64(let value): Int64(exactly: value).map(SurrealValue.int) ?? .decimal(String(value))
        case .f16(let value): .double(value.doubleValue)
        case .f32(let value): .double(Double(value))
        }
    }

    /// The integer, if this is one of the integer kinds and it fits `T`.
    public func integer<T: FixedWidthInteger>(as type: T.Type = T.self) -> T? {
        switch self {
        case .i8(let value): T(exactly: value)
        case .u8(let value): T(exactly: value)
        case .i16(let value): T(exactly: value)
        case .u16(let value): T(exactly: value)
        case .i32(let value): T(exactly: value)
        case .u32(let value): T(exactly: value)
        case .u64(let value): T(exactly: value)
        case .f16, .f32: nil
        }
    }

    /// The value as a `Double`. Exact for every kind except a `u64` above
    /// 2^53.
    public var doubleValue: Double {
        switch self {
        case .i8(let value): Double(value)
        case .u8(let value): Double(value)
        case .i16(let value): Double(value)
        case .u16(let value): Double(value)
        case .i32(let value): Double(value)
        case .u32(let value): Double(value)
        case .u64(let value): Double(value)
        case .f16(let value): value.doubleValue
        case .f32(let value): Double(value)
        }
    }

    /// A SurrealQL literal of the same kind (`5u8`, `1.5f32`, `<f16>NaN`).
    /// Needs a 4.0 server to parse.
    public var sqlLiteral: String {
        switch self {
        case .i8(let value): "\(value)i8"
        case .u8(let value): "\(value)u8"
        case .i16(let value): "\(value)i16"
        case .u16(let value): "\(value)u16"
        case .i32(let value): "\(value)i32"
        case .u32(let value): "\(value)u32"
        case .u64(let value): "\(value)u64"
        case .f16(let value): Self.floatLiteral(value.doubleValue, suffix: "f16")
        case .f32(let value): Self.floatLiteral(Double(value), suffix: "f32", shortest: "\(value)")
        }
    }

    private static func floatLiteral(_ value: Double, suffix: String, shortest: String? = nil) -> String {
        if value.isNaN { return "<\(suffix)>NaN" }
        if value.isInfinite { return value > 0 ? "<\(suffix)>Infinity" : "<\(suffix)>-Infinity" }
        // Swift prints the shortest text that reads back as the same value,
        // which for a Float is shorter than its Double's.
        return (shortest ?? "\(value)") + suffix
    }
}

/// An IEEE 754 binary16 (`f16`) value, stored as its bits so it works on
/// every platform, including Intel Macs, where Swift's `Float16` isn't
/// available.
///
/// Two values are equal when their bits are: `NaN == NaN`, and `-0` differs
/// from `0`.
public struct SurrealFloat16: Sendable, Hashable, CustomStringConvertible {
    public let bitPattern: UInt16

    public init(bitPattern: UInt16) {
        self.bitPattern = bitPattern
    }

    /// The nearest `f16` to `value`, ties to even. Values beyond the largest
    /// `f16` (65504) round to infinity.
    public init(_ value: Double) {
        self.init(bitPattern: Self.roundedBits(value))
    }

    /// `value` as an `f16`, or `nil` if it isn't exactly one.
    public init?(exactly value: Double) {
        let rounded = SurrealFloat16(value)
        guard rounded.doubleValue.bitPattern == value.bitPattern || (value.isNaN && rounded.isNaN) else {
            return nil
        }
        self = rounded
    }

    public var isNaN: Bool {
        bitPattern & 0x7C00 == 0x7C00 && bitPattern & 0x03FF != 0
    }

    public var doubleValue: Double {
        let negative = bitPattern & 0x8000 != 0
        let exponent = Int((bitPattern >> 10) & 0x1F)
        let fraction = Double(bitPattern & 0x03FF)
        let magnitude: Double
        switch exponent {
        case 0x1F:
            magnitude = fraction == 0 ? .infinity : .nan
        case 0:
            magnitude = fraction * 0x1p-24
        default:
            magnitude = (1 + fraction / 1024) * Double(sign: .plus, exponent: exponent - 15, significand: 1)
        }
        return negative ? -magnitude : magnitude
    }

    public var description: String {
        "\(doubleValue)"
    }

    private static func roundedBits(_ value: Double) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (bits >> 48) & 0x8000)
        let exponent = Int((bits >> 52) & 0x7FF)
        let fraction = bits & 0x000F_FFFF_FFFF_FFFF
        if exponent == 0x7FF {
            return sign | (fraction == 0 ? 0x7C00 : 0x7E00)
        }
        // The f16 exponent, before bias checks. A double subnormal is far
        // below the smallest f16 and falls out as zero below.
        let halfExponent = exponent - 1023 + 15
        if halfExponent >= 0x1F {
            return sign | 0x7C00
        }
        // 53 bits of significand, shifted down to the 11 an f16 keeps (or
        // fewer, for a subnormal result), rounding to nearest, ties to even.
        let significand = fraction | (exponent == 0 ? 0 : 1 << 52)
        let shift = 42 + max(0, 1 - halfExponent)
        var kept: UInt64 = 0
        if shift < 64 {
            kept = significand >> UInt64(shift)
            let rest = significand & ((1 << UInt64(shift)) - 1)
            let half: UInt64 = 1 << UInt64(shift - 1)
            if rest > half || (rest == half && kept & 1 == 1) {
                kept += 1
            }
        }
        // For a normal result `kept` includes the implicit bit, so adding it
        // to (exponent - 1) << 10 sets the exponent, and a carry out of the
        // fraction moves into the exponent as it should.
        let magnitude = UInt64(max(halfExponent - 1, 0)) << 10 + kept
        return sign | UInt16(min(magnitude, 0x7C00))
    }
}
