import Foundation

/// The range of server versions this SDK supports, and the check `connect()`
/// runs against it.
public enum ServerVersion {
    /// The oldest supported server version (inclusive).
    public static let minimum = "3.0.0"
    /// The first unsupported server version (exclusive).
    public static let maximum = "5.0.0"

    /// Whether `version` (e.g. `"3.3.4"`, `"surrealdb-3.4.0-nightly+…"`) is
    /// at least ``minimum`` and below ``maximum``. Pre-release and build
    /// suffixes are ignored, so `3.0.0-beta.1` counts as 3.0.0 and
    /// `5.0.0-alpha.1` is rejected.
    public static func isSupported(_ version: String) -> Bool {
        guard let parsed = core(of: version) else { return false }
        return compare(parsed, core(of: minimum)!) >= 0 && compare(parsed, core(of: maximum)!) < 0
    }

    static func check(_ version: String) throws {
        guard isSupported(version) else {
            throw SurrealError.unsupportedServerVersion(
                version: version,
                supported: ">= \(minimum), < \(maximum)"
            )
        }
    }

    static func strip(_ raw: String) -> String {
        var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("surrealdb-") {
            version.removeFirst("surrealdb-".count)
        }
        return version
    }

    /// `major.minor.patch` as numbers, ignoring anything after `-` or `+`.
    private static func core(of version: String) -> [Int]? {
        let stripped = strip(version)
        let numeric = stripped.prefix(while: { $0 != "-" && $0 != "+" })
        let parts = numeric.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? -1 : 1
        }
        return 0
    }
}
