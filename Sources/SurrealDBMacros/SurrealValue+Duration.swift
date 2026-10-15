import Foundation

/// `SurrealValue.duration` holds SurrealQL's text form (`"1h30m"`). The wire
/// form is whole seconds plus nanoseconds, so these convert between the two.
extension SurrealValue {
    /// A duration from whole seconds and nanoseconds, in the canonical text
    /// form the server renders (`90 * 60` seconds → `"1h30m"`).
    public static func duration(seconds: UInt64, nanoseconds: UInt32 = 0) -> SurrealValue {
        .duration(DurationText.format(seconds: seconds, nanoseconds: nanoseconds))
    }

    /// The seconds and nanoseconds of a `.duration`, or `nil` for any other
    /// value or for text that isn't a valid duration.
    public var durationComponents: (seconds: UInt64, nanoseconds: UInt32)? {
        guard case .duration(let text) = self else { return nil }
        return DurationText.parse(text)
    }
}

enum DurationText {
    private static let nanosPerSecond: UInt64 = 1_000_000_000

    /// Nanoseconds per unit. Longest suffix first, so `"ms"` is never read as
    /// `"m"` and `"ns"`/`"us"` never as `"s"`.
    private static let units: [(suffix: String, nanoseconds: UInt64)] = [
        ("ns", 1),
        ("µs", 1_000),
        ("us", 1_000),
        ("ms", 1_000_000),
        ("y", 365 * 24 * 60 * 60 * nanosPerSecond),
        ("w", 7 * 24 * 60 * 60 * nanosPerSecond),
        ("d", 24 * 60 * 60 * nanosPerSecond),
        ("h", 60 * 60 * nanosPerSecond),
        ("m", 60 * nanosPerSecond),
        ("s", nanosPerSecond),
    ]

    /// Parses simple (`"500ms"`) and compound (`"1h30m"`) forms. Works in
    /// seconds and nanoseconds separately, so durations too long to fit in
    /// 64 bits of nanoseconds still parse.
    static func parse(_ text: String) -> (seconds: UInt64, nanoseconds: UInt32)? {
        var remainder = Substring(text)
        guard !remainder.isEmpty else { return nil }

        var seconds: UInt64 = 0
        var nanos: UInt64 = 0

        while !remainder.isEmpty {
            let digits = remainder.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, let amount = UInt64(digits) else { return nil }
            remainder = remainder.dropFirst(digits.count)

            guard let unit = units.first(where: { remainder.hasPrefix($0.suffix) }) else { return nil }
            remainder = remainder.dropFirst(unit.suffix.count)

            let wholeSeconds: UInt64
            let extraNanos: UInt64
            if unit.nanoseconds >= nanosPerSecond {
                let (product, overflow) = amount.multipliedReportingOverflow(by: unit.nanoseconds / nanosPerSecond)
                guard !overflow else { return nil }
                wholeSeconds = product
                extraNanos = 0
            } else {
                let perSecond = nanosPerSecond / unit.nanoseconds
                wholeSeconds = amount / perSecond
                extraNanos = (amount % perSecond) * unit.nanoseconds
            }

            nanos += extraNanos
            let (carried, carryOverflow) = wholeSeconds.addingReportingOverflow(nanos / nanosPerSecond)
            let (sum, overflow) = seconds.addingReportingOverflow(carried)
            guard !carryOverflow, !overflow else { return nil }
            seconds = sum
            nanos %= nanosPerSecond
        }

        return (seconds, UInt32(nanos))
    }

    /// The server's canonical form: largest unit first, zero parts left out,
    /// and `"0ns"` for zero.
    /// Nanoseconds of a second or more carry into the seconds; if that would
    /// overflow, they're written out as sub-second units instead, so the
    /// text still holds the exact value.
    static func format(seconds: UInt64, nanoseconds: UInt32) -> String {
        let (carried, overflow) = seconds.addingReportingOverflow(UInt64(nanoseconds) / nanosPerSecond)
        var remaining = overflow ? seconds : carried
        var parts = ""

        let secondUnits: [(String, UInt64)] = [
            ("y", 365 * 24 * 60 * 60), ("w", 7 * 24 * 60 * 60), ("d", 24 * 60 * 60),
            ("h", 60 * 60), ("m", 60), ("s", 1),
        ]
        for (suffix, divisor) in secondUnits {
            let count = remaining / divisor
            if count > 0 {
                parts += "\(count)\(suffix)"
                remaining -= count * divisor
            }
        }

        var subsecond = overflow ? UInt64(nanoseconds) : UInt64(nanoseconds) % nanosPerSecond
        for (suffix, divisor) in [("ms", UInt64(1_000_000)), ("µs", 1_000), ("ns", 1)] {
            let count = subsecond / divisor
            if count > 0 {
                parts += "\(count)\(suffix)"
                subsecond -= count * divisor
            }
        }

        return parts.isEmpty ? "0ns" : parts
    }
}
