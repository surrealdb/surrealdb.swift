import Foundation

public struct QueryErrorDetail: Sendable, Hashable {
    public let index: Int
    public let message: String
    public let kind: String?
    public let details: SurrealValue?

    public init(index: Int, message: String, kind: String? = nil, details: SurrealValue?) {
        self.index = index
        self.message = message
        self.kind = kind
        self.details = details
    }

    /// The typed error taxonomy for this statement's failure. See ``ServerErrorKind``.
    public var typedKind: ServerErrorKind {
        ServerErrorKind.parse(kind: kind, details: details)
    }
}

public enum SurrealError: Error, Sendable {
    case invalidEndpoint(String)
    case notConnected
    case connectionLost(cause: (any Error)?)
    case unsupportedFeature(String)
    case invalidCredentials(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case serverError(RPCErrorObject)
    case queryErrors([QueryErrorDetail])
    case timeout
    case invalidSession(SessionID)
    /// The server's version is outside the range this SDK supports. Turn off
    /// `SurrealClientOptions.checkServerVersion` to connect anyway.
    case unsupportedServerVersion(version: String, supported: String)

    public var message: String {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid endpoint: \(value)"
        case .notConnected:
            return "The client is not connected."
        case .connectionLost(let cause):
            if let cause {
                return "Connection lost: \(cause.localizedDescription)"
            }
            return "Connection lost."
        case .unsupportedFeature(let feature):
            return "Unsupported feature: \(feature)"
        case .invalidCredentials(let message):
            return "Invalid credentials: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .httpError(let code, let body) where !body.isEmpty:
            return "HTTP \(code): \(body)"
        case .httpError(let code, _):
            return "HTTP \(code)"
        case .serverError(let payload):
            return payload.message
        case .queryErrors(let errors) where errors.count == 1:
            let e = errors[0]
            return "Query statement #\(e.index) failed: \(e.message)"
        case .queryErrors(let errors):
            let indices = errors.map { "#\($0.index)" }.joined(separator: ", ")
            return "\(errors.count) query statements failed (at \(indices))"
        case .timeout:
            return "The request timed out."
        case .invalidSession(let id):
            return "No such session: \(id)."
        case .unsupportedServerVersion(let version, let supported):
            return "SurrealDB \(version) is not supported; this SDK supports \(supported)."
        }
    }

    public var isTransient: Bool {
        switch self {
        case .timeout, .connectionLost:
            return true
        case .httpError(let code, _):
            return code == 429 || code == 503 || code == 504
        default:
            return false
        }
    }

    /// The typed server error taxonomy, when this is a `.serverError`.
    ///
    /// Replaces string-comparing the raw `kind` on `RPCErrorObject` with a typed
    /// hierarchy (see ``ServerErrorKind``) that distinguishes, for example, an
    /// expired auth token from a generic invalid-auth failure, a not-found resource
    /// from an already-exists conflict, or a retryable transaction conflict from
    /// another query failure.
    public var serverErrorKind: ServerErrorKind? {
        guard case .serverError(let payload) = self else {
            return nil
        }
        return payload.typedKind
    }

    /// True if the server rejected the request because the auth token has
    /// expired, over either transport.
    public var isTokenExpired: Bool {
        if serverErrorKind?.isTokenExpired == true { return true }
        if case .httpError(401, let body) = self {
            return body.localizedCaseInsensitiveContains("token has expired")
        }
        return false
    }
}

extension SurrealError: LocalizedError {
    public var errorDescription: String? { message }

    public var failureReason: String? {
        switch self {
        case .serverError(let obj):
            return "Server error kind: \(obj.typedKind)"
        case .queryErrors(let errors):
            return errors.map { "#\($0.index): \($0.message)" }.joined(separator: "\n")
        case .connectionLost(let cause):
            return cause?.localizedDescription
        case .httpError(let code, let body) where !body.isEmpty:
            return "HTTP \(code): \(body)"
        default:
            return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidEndpoint:
            return "Check that the endpoint URL is well-formed and uses ws://, wss://, http://, or https://."
        case .notConnected:
            return "Call connect() before performing operations."
        case .connectionLost:
            return "Check network connectivity and retry."
        case .httpError(401, _):
            return "Re-authenticate and retry."
        case .serverError(let obj) where obj.typedKind.isTokenExpired || obj.typedKind.isSessionExpired:
            return "Re-authenticate and retry."
        case .serverError(let obj) where obj.typedKind.isTransactionConflict:
            return "Safe to retry: a concurrent transaction modified the same data."
        case .timeout:
            return "Retry the operation or increase requestTimeout in SurrealClientOptions."
        case .invalidSession:
            return "The session was closed or never existed; create a new one via newSession()/forkSession()."
        case .unsupportedServerVersion:
            return "Use a supported server version, or set checkServerVersion to false in SurrealClientOptions."
        default:
            return nil
        }
    }
}
