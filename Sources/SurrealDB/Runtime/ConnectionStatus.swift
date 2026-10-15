import Foundation

/// Where a client's connection stands. Watch it with
/// `SurrealClient.connectionStatusUpdates()`.
public enum SurrealConnectionStatus: Sendable, Hashable {
    /// Not connected: before `connect()`, after `close()`, after `connect()`
    /// failed, or once a WebSocket has given up reconnecting.
    case disconnected
    /// `connect()` is in progress.
    case connecting
    /// Connected and ready. After a WebSocket reconnect, this comes once the
    /// sessions and live queries have been restored.
    case connected
    /// The WebSocket dropped and the client is retrying; `attempt` counts
    /// from 1 up to `maxReconnectAttempts`.
    case reconnecting(attempt: Int)
}

/// Holds the current status and fans changes out to every subscriber.
final class ConnectionStatusBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var status: SurrealConnectionStatus = .disconnected
    private var subscribers: [UUID: AsyncStream<SurrealConnectionStatus>.Continuation] = [:]

    var current: SurrealConnectionStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// Records a new status and tells subscribers, unless it's unchanged.
    func send(_ newStatus: SurrealConnectionStatus) {
        lock.lock()
        guard newStatus != status else {
            lock.unlock()
            return
        }
        status = newStatus
        let continuations = Array(subscribers.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield(newStatus)
        }
    }

    /// A stream that starts with the current status, then yields each change.
    func updates() -> AsyncStream<SurrealConnectionStatus> {
        let (stream, continuation) = AsyncStream<SurrealConnectionStatus>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        lock.lock()
        subscribers[id] = continuation
        continuation.yield(status)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}
