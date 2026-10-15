import Foundation

/// Runs `operation`, throwing `SurrealError.timeout` if it hasn't finished
/// within `seconds`. The operation is cancelled on timeout.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0, seconds.isFinite else {
        return try await operation()
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SurrealError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw SurrealError.timeout
        }
        return result
    }
}
