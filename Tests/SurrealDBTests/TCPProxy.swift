import Foundation
import Network

/// A local TCP proxy in front of the test server, so tests can drop
/// connections, refuse new ones, or stall traffic without touching the server
/// itself (which other tests share).
final class TCPProxy: @unchecked Sendable {
    private let upstreamHost: NWEndpoint.Host
    private let upstreamPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "TCPProxy")
    private var listener: NWListener?
    private var pairs: [(client: NWConnection, upstream: NWConnection)] = []
    private var accepted = 0
    private var stalled = false
    private var rejecting = false

    private(set) var port: UInt16 = 0

    /// `upstream` is `host:port`.
    init(upstream: String) {
        let parts = upstream.split(separator: ":")
        upstreamHost = NWEndpoint.Host(String(parts[0]))
        upstreamPort = NWEndpoint.Port(rawValue: UInt16(parts.count > 1 ? String(parts[1]) : "8000") ?? 8000)!
    }

    /// Starts listening, on the same port as before when restarted.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = port == 0
            ? try NWListener(using: parameters)
            : try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        let ready = AsyncStream<Result<UInt16, Error>>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.continuation.yield(.success(listener.port?.rawValue ?? 0))
            case .failed(let error):
                ready.continuation.yield(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)

        for await result in ready.stream {
            port = try result.get()
            return
        }
    }

    /// Stops accepting connections. Existing ones stay up.
    func stopListening() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    /// Cuts every proxied connection, as if the network dropped.
    func dropConnections() {
        queue.sync {
            for pair in pairs {
                pair.client.cancel()
                pair.upstream.cancel()
            }
            pairs.removeAll()
        }
    }

    /// While stalled, bytes are read but not forwarded, so requests hang.
    func setStalled(_ stalled: Bool) {
        queue.sync { self.stalled = stalled }
    }

    /// While rejecting, new connections are counted and closed at once, like
    /// a host that's up but refusing service.
    func setRejecting(_ rejecting: Bool) {
        queue.sync { self.rejecting = rejecting }
    }

    var acceptedConnections: Int {
        queue.sync { accepted }
    }

    func shutdown() {
        stopListening()
        dropConnections()
    }

    private func accept(_ client: NWConnection) {
        accepted += 1
        if rejecting {
            // Answer with a 503 rather than resetting the connection:
            // URLSession quietly retries a handshake whose connection resets,
            // which would make one attempt look like several.
            client.start(queue: queue)
            client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
            }
            return
        }
        let upstream = NWConnection(host: upstreamHost, port: upstreamPort, using: .tcp)
        pairs.append((client, upstream))
        client.start(queue: queue)
        upstream.start(queue: queue)
        pump(from: client, to: upstream)
        pump(from: upstream, to: client)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, !self.stalled {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            self.pump(from: source, to: destination)
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
    timeout: TimeInterval = 10,
    _ condition: @Sendable () async throws -> Bool
) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return try await condition()
}
