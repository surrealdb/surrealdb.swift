import Foundation

actor WebSocketRPCEngine: LiveRPCEngine, SessionCapableRPCEngine {
    private let endpoint: URL
    private let urlSession: URLSession
    private let clientOptions: SurrealClientOptions
    private let wsOptions: SurrealWebSocketOptions
    private let codec: any WireCodec

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var pending: [String: CheckedContinuation<RPCResponseEnvelope, Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var liveContinuations: [UUID: AsyncStream<LiveWireEvent>.Continuation] = [:]
    private var reconnectContinuation: AsyncStream<Void>.Continuation?

    private var connected = false
    private var closedByClient = false

    /// Bumped for every socket. The receive and ping loops both report a dead
    /// socket; only the first report for the current socket is acted on, so
    /// one drop starts one reconnect loop, not two.
    private var generation = 0

    /// Bumped for every connection attempt. An attempt that finishes its
    /// handshake after a newer one started (an overlapping `connect()`, or
    /// one that cancelled a reconnect mid-handshake) discards its socket
    /// instead of replacing the newer one's.
    private var attempt = 0

    /// The `connect()` in flight, which overlapping calls wait for.
    private var pendingConnect: Task<Void, Error>?
    /// The connect() calls waiting on `pendingConnect`.
    private var connectCallers: Set<UUID> = []
    /// The socket an attempt is handshaking on, before it becomes `task`.
    /// close() cancels it, so the attempt fails at once.
    private var connectingSocket: URLSessionWebSocketTask?

    init(
        endpoint: URL,
        clientOptions: SurrealClientOptions,
        wsOptions: SurrealWebSocketOptions,
        codec: any WireCodec,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = Endpoint.asWebSocket(endpoint)
        self.clientOptions = clientOptions
        self.wsOptions = wsOptions
        self.codec = codec
        self.urlSession = urlSession
    }

    func connect() async throws {
        if let pendingConnect {
            return try await join(pendingConnect)
        }
        closedByClient = false
        reconnectTask?.cancel()
        reconnectTask = nil
        let connecting = Task { try await self.establishSocket() }
        pendingConnect = connecting
        defer {
            // close() may have dropped this attempt and a newer connect()
            // started its own.
            if pendingConnect == connecting {
                pendingConnect = nil
            }
        }
        try await join(connecting)
    }

    /// Waits for a connection attempt on behalf of one connect() caller.
    /// The attempt is shared, so it's abandoned only once every caller
    /// waiting on it has been cancelled.
    private func join(_ attempt: Task<Void, Error>) async throws {
        let caller = UUID()
        connectCallers.insert(caller)
        defer { connectCallers.remove(caller) }
        try await withTaskCancellationHandler {
            try await attempt.value
        } onCancel: {
            Task { await self.connectCallerCancelled(caller, attempt) }
        }
        try Task.checkCancellation()
    }

    private func connectCallerCancelled(_ caller: UUID, _ attempt: Task<Void, Error>) {
        connectCallers.remove(caller)
        guard connectCallers.isEmpty, pendingConnect == attempt else { return }
        attempt.cancel()
        pendingConnect = nil
        connectingSocket?.cancel(with: .goingAway, reason: nil)
        connectingSocket = nil
    }

    func close() async {
        closedByClient = true
        connected = false
        generation += 1

        reconnectTask?.cancel()
        reconnectTask = nil
        pendingConnect?.cancel()
        pendingConnect = nil
        connectingSocket?.cancel(with: .normalClosure, reason: nil)
        connectingSocket = nil

        tearDownSocket(closeCode: .normalClosure)

        failPending(with: SurrealError.notConnected)
        finishAllLiveStreams()

        reconnectContinuation?.finish()
        reconnectContinuation = nil
    }

    func reconnectEvents() -> AsyncStream<Void> {
        reconnectContinuation?.finish()
        return AsyncStream { continuation in
            self.reconnectContinuation = continuation
        }
    }

    /// Sends a request and waits for its reply. Throws `SurrealError.timeout`
    /// after `requestTimeout`, and `CancellationError` as soon as the calling
    /// task is cancelled; either way the request is forgotten, so a late reply
    /// is dropped.
    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        _ = session
        guard connected else {
            throw SurrealError.notConnected
        }

        // The server echoes UUID-shaped ids lowercased over JSON, so match
        // replies case-insensitively.
        let id = request.id.lowercased()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs on the actor before onCancel's task can, so a request
                // cancelled from here on is always found in `pending`.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                startTimer(for: id, method: request.method)
                Task {
                    do {
                        let payload = try codec.encode(request)
                        try await self.rawSend(payload, requestID: id)
                    } catch {
                        self.failPending(requestID: id, with: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.requestEnded(id, method: request.method, with: CancellationError()) }
        }
    }

    /// Methods that change the connection's server-side state. If one times
    /// out or is cancelled, the server may still apply it after the client
    /// has given up and kept its old idea of that state.
    private static let stateChangingMethods: Set<String> = [
        "use", "signin", "signup", "authenticate", "invalidate", "let", "unset",
        "reset", "attach", "detach", "begin",
    ]

    private func startTimer(for id: String, method: String) {
        let timeout = clientOptions.requestTimeout
        guard timeout > 0, timeout.isFinite else { return }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.requestEnded(id, method: method, with: SurrealError.timeout)
        }
    }

    /// Gives up on a request that timed out or was cancelled before its reply.
    private func requestEnded(_ id: String, method: String, with error: Error) {
        guard pending[id] != nil else { return }
        failPending(requestID: id, with: error)
        // The server may still apply it. Start over on a new socket, whose
        // state the client replays from what it knows, rather than guess.
        if Self.stateChangingMethods.contains(method), connected {
            handleSocketTermination(generation: generation, error: error)
        }
    }

    /// Removes a pending request and its timer.
    private func takePending(_ id: String) -> CheckedContinuation<RPCResponseEnvelope, Error>? {
        timers.removeValue(forKey: id)?.cancel()
        return pending.removeValue(forKey: id)
    }

    func openLiveStream(for queryID: UUID) async -> AsyncStream<LiveWireEvent> {
        AsyncStream { continuation in
            liveContinuations[queryID] = continuation
            continuation.onTermination = { [queryID] _ in
                Task {
                    await self.closeLiveStream(for: queryID)
                }
            }
        }
    }

    func closeLiveStream(for queryID: UUID) async {
        guard let continuation = liveContinuations.removeValue(forKey: queryID) else {
            return
        }
        continuation.finish()
    }

    // MARK: - Socket lifecycle

    /// Opens a socket and waits for the server to answer an RPC `ping`, so a
    /// dead or unreachable host fails here instead of "connecting" and then
    /// failing every request. (A WebSocket-level ping sent before the
    /// handshake finishes can go unanswered forever, so it isn't used here.)
    private func establishSocket() async throws {
        attempt += 1
        let thisAttempt = attempt
        tearDownSocket(closeCode: .goingAway)

        let socket = urlSession.webSocketTask(with: endpoint, protocols: codec.websocketSubprotocols)
        socket.resume()
        connectingSocket = socket
        defer {
            if connectingSocket === socket {
                connectingSocket = nil
            }
        }

        do {
            try await withTimeout(seconds: clientOptions.requestTimeout) { [codec] in
                try await Self.handshake(socket, codec: codec)
            }
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            if let error = error as? SurrealError {
                throw error
            }
            throw SurrealError.connectionLost(cause: error)
        }

        // close() may have run while we waited, or a newer attempt started.
        guard !closedByClient, thisAttempt == attempt else {
            socket.cancel(with: .normalClosure, reason: nil)
            throw SurrealError.notConnected
        }

        generation += 1
        task = socket
        connected = true

        startReceiveLoop(generation: generation)
        startPingLoop(generation: generation)
    }

    private static func handshake(_ socket: URLSessionWebSocketTask, codec: any WireCodec) async throws {
        let id = UUID().uuidString.lowercased()
        let request = RPCRequest(id: id, method: "ping", params: nil, session: nil, txn: nil)
        try await socket.send(.data(try codec.encode(request)))

        // Nothing else is in flight on a new socket, so the next message is
        // the reply.
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let bytes):
            data = bytes
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw SurrealError.invalidResponse("Unexpected WebSocket message during connect.")
        }
        let envelope = try codec.decodeEnvelope(data)
        if let error = envelope.error {
            throw SurrealError.serverError(error)
        }
        guard envelope.id?.lowercased() == id else {
            throw SurrealError.invalidResponse("Unexpected reply to the connect ping.")
        }
    }

    private func tearDownSocket(closeCode: URLSessionWebSocketTask.CloseCode) {
        receiveTask?.cancel()
        receiveTask = nil

        pingTask?.cancel()
        pingTask = nil

        task?.cancel(with: closeCode, reason: nil)
        task = nil
    }

    private func rawSend(_ data: Data, requestID: String) async throws {
        guard connected, let task else {
            throw SurrealError.notConnected
        }

        do {
            try await task.send(.data(data))
        } catch {
            failPending(requestID: requestID, with: error)
            throw error
        }
    }

    private func startReceiveLoop(generation: Int) {
        guard let socket = task else { return }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    switch message {
                    case .data(let data):
                        try await self.handleIncoming(data)
                    case .string(let text):
                        try await self.handleIncoming(Data(text.utf8))
                    @unknown default:
                        continue
                    }
                } catch {
                    await self?.handleSocketTermination(generation: generation, error: error)
                    return
                }
            }
        }
    }

    private func startPingLoop(generation: Int) {
        guard let socket = task else { return }
        let pingInterval = max(clientOptions.pingInterval, 1)
        let pongTimeout = clientOptions.requestTimeout
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                do {
                    // A peer that stops answering is as dead as one that
                    // closed the socket.
                    try await withTimeout(seconds: pongTimeout) {
                        try await Self.ping(socket)
                    }
                } catch {
                    await self?.handleSocketTermination(generation: generation, error: error)
                    return
                }
            }
        }
    }

    private static func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func handleIncoming(_ data: Data) async throws {
        let response: RPCResponseEnvelope
        do {
            response = try codec.decodeEnvelope(data)
        } catch {
            // A reply that won't decode (say, a malformed tag in its result)
            // fails its own request; the connection is fine.
            if let id = codec.requestID(in: data)?.lowercased() {
                takePending(id)?.resume(throwing: error as? SurrealError ?? SurrealError.invalidResponse("Couldn't decode the reply: \(error)"))
                return
            }
            // A message that can't be matched to anything might have been any
            // reply or notification: treat the connection as broken rather
            // than leave its request waiting.
            throw error
        }

        if let id = response.id?.lowercased(), let continuation = takePending(id) {
            continuation.resume(returning: response)
            return
        }

        guard let liveEvent = codec.decodeLiveEvent(from: response) else {
            return
        }

        liveContinuations[liveEvent.queryID]?.yield(liveEvent)
        if liveEvent.action == .killed {
            // KILLED is the last notification for this id.
            liveContinuations.removeValue(forKey: liveEvent.queryID)?.finish()
        }
    }

    // MARK: - Reconnect

    private func handleSocketTermination(generation: Int, error: Error) {
        // A stale report: this socket was already replaced or closed.
        guard generation == self.generation, connected else { return }

        connected = false
        tearDownSocket(closeCode: .goingAway)

        failPending(with: SurrealError.connectionLost(cause: error))
        finishAllLiveStreams()

        guard !closedByClient, wsOptions.reconnectEnabled, wsOptions.maxReconnectAttempts > 0 else {
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        for attempt in 1...wsOptions.maxReconnectAttempts {
            let delay = Self.backoffDelay(attempt: attempt, options: wsOptions)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled, !closedByClient else { return }

            do {
                try await establishSocket()
                reconnectContinuation?.yield(())
                return
            } catch {
                continue
            }
        }
    }

    /// `base * 2^(attempt - 1)`, capped at `reconnectMaxDelay`.
    static func backoffDelay(attempt: Int, options: SurrealWebSocketOptions) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 30)
        let delay = options.reconnectBaseDelay * pow(2.0, Double(exponent))
        return min(max(delay, 0), max(options.reconnectMaxDelay, 0))
    }

    // MARK: - Pending requests and live streams

    private func failPending(requestID: String, with error: Error) {
        guard let continuation = takePending(requestID) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll(keepingCapacity: false)
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func finishAllLiveStreams() {
        let continuations = liveContinuations.values
        liveContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.finish()
        }
    }
}
