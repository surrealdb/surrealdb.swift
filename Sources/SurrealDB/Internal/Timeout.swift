import Foundation

/// Runs `operation`, throwing `SurrealError.timeout` if it hasn't finished
/// within `seconds`, and `CancellationError` as soon as the caller is
/// cancelled. In both cases the operation is cancelled but not waited for:
/// some URLSession calls ignore cancellation, and a task group would block
/// until they returned.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.setWork(work)
            if seconds > 0, seconds.isFinite {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    race.finish(.failure(SurrealError.timeout))
                }
            }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes a continuation with whichever result arrives first, and cancels
/// the losing work.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var work: Task<Void, Never>?
    private var done = false

    func start(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            // Cancelled before the continuation existed.
            done = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setWork(_ work: Task<Void, Never>) {
        lock.lock()
        let cancelNow = done
        if !done { self.work = work }
        lock.unlock()
        if cancelNow { work.cancel() }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        guard let continuation else {
            if pending == nil { pending = result }
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        let work = self.work
        self.work = nil
        lock.unlock()

        work?.cancel()
        continuation.resume(with: result)
    }
}
