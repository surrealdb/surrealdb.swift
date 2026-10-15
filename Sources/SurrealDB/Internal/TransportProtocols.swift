import Foundation

protocol RPCEngine: Actor {
    func connect() async throws
    func close() async
    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope
}

protocol LiveRPCEngine: RPCEngine {
    func openLiveStream(for queryID: UUID) async -> AsyncStream<LiveWireEvent>
    func closeLiveStream(for queryID: UUID) async
    /// Re-keys an open stream after its live query was re-issued under a new
    /// id, delivering anything already buffered for the new id.
    func moveLiveStream(from oldID: UUID, to newID: UUID) async

    /// Fires each time the engine successfully re-establishes a connection
    /// after an unexpected drop (not on the initial `connect()`). Consumers
    /// use this to replay session state (namespace/database/auth) that the
    /// server loses when a connection is re-established.
    func reconnectEvents() -> AsyncStream<Void>
}

/// Marker for engines whose connections can multiplex more than one
/// server-side session (via `attach`/`detach`). Orthogonal to `LiveRPCEngine`
/// even though only `WebSocketRPCEngine` conforms to both today.
protocol SessionCapableRPCEngine: RPCEngine {}
