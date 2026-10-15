import Foundation

public struct SurrealClientOptions: Sendable {
    public var requestTimeout: TimeInterval
    public var pingInterval: TimeInterval

    public init(
        requestTimeout: TimeInterval = 20,
        pingInterval: TimeInterval = 30
    ) {
        self.requestTimeout = requestTimeout
        self.pingInterval = pingInterval
    }
}

public struct SurrealWebSocketOptions: Sendable {
    /// Whether to reconnect after the connection drops unexpectedly.
    public var reconnectEnabled: Bool
    /// How many reconnect attempts to make after a drop before giving up.
    /// The count starts again after each successful reconnect.
    public var maxReconnectAttempts: Int
    /// The delay before the first attempt; each later attempt doubles it.
    public var reconnectBaseDelay: TimeInterval
    /// The longest delay between two attempts.
    public var reconnectMaxDelay: TimeInterval

    public init(
        reconnectEnabled: Bool = true,
        maxReconnectAttempts: Int = 8,
        reconnectBaseDelay: TimeInterval = 0.5,
        reconnectMaxDelay: TimeInterval = 30
    ) {
        self.reconnectEnabled = reconnectEnabled
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
    }
}

/// Identifies a logical session multiplexed over the same physical connection.
/// `nil` refers to the connection's default/root session.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public struct SessionContext: Sendable {
    public var namespace: String?
    public var database: String?
    public var accessToken: String?
    public var variables: [String: SurrealValue]

    public init(
        namespace: String? = nil,
        database: String? = nil,
        accessToken: String? = nil,
        variables: [String: SurrealValue] = [:]
    ) {
        self.namespace = namespace
        self.database = database
        self.accessToken = accessToken
        self.variables = variables
    }
}

public struct AuthTokens: Sendable, Hashable {
    public let access: String
    public let refresh: String?

    public init(access: String, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }
}

public enum SignInCredentials: Sendable {
    case root(username: String, password: String)
    case namespace(namespace: String, username: String, password: String)
    case database(namespace: String, database: String, username: String, password: String)
    case accessVariables(namespace: String? = nil, database: String? = nil, access: String, variables: [String: SurrealValue])
    case accessBearer(namespace: String? = nil, database: String? = nil, access: String, key: String)

    func payload(using session: SessionContext) throws -> SurrealValue {
        switch self {
        case .root(let username, let password):
            return .object([
                "user": .string(username),
                "pass": .string(password),
            ])
        case .namespace(let namespace, let username, let password):
            return .object([
                "ns": .string(namespace),
                "user": .string(username),
                "pass": .string(password),
            ])
        case .database(let namespace, let database, let username, let password):
            return .object([
                "ns": .string(namespace),
                "db": .string(database),
                "user": .string(username),
                "pass": .string(password),
            ])
        case let .accessVariables(namespace, database, access, variables):
            let ns = namespace ?? session.namespace
            let db = database ?? session.database
            if (namespace == nil && database != nil) || (db != nil && ns == nil) {
                throw SurrealError.invalidCredentials("Namespace is required whenever database is provided.")
            }
            var payload = variables
            payload["ac"] = .string(access)
            if let ns {
                payload["ns"] = .string(ns)
            }
            if let db {
                payload["db"] = .string(db)
            }
            return .object(payload)
        case let .accessBearer(namespace, database, access, key):
            let ns = namespace ?? session.namespace
            let db = database ?? session.database
            if (namespace == nil && database != nil) || (db != nil && ns == nil) {
                throw SurrealError.invalidCredentials("Namespace is required whenever database is provided.")
            }
            var payload: [String: SurrealValue] = [
                "ac": .string(access),
                "key": .string(key),
            ]
            if let ns {
                payload["ns"] = .string(ns)
            }
            if let db {
                payload["db"] = .string(db)
            }
            return .object(payload)
        }
    }
}

public enum SignUpCredentials: Sendable {
    case accessRecord(namespace: String? = nil, database: String? = nil, access: String, variables: [String: SurrealValue])

    func payload(using session: SessionContext) throws -> SurrealValue {
        switch self {
        case let .accessRecord(namespace, database, access, variables):
            let ns = namespace ?? session.namespace
            let db = database ?? session.database
            if (namespace == nil && database != nil) || (db != nil && ns == nil) {
                throw SurrealError.invalidCredentials("Namespace is required whenever database is provided.")
            }
            var payload = variables
            payload["ac"] = .string(access)
            if let ns {
                payload["ns"] = .string(ns)
            }
            if let db {
                payload["db"] = .string(db)
            }
            return .object(payload)
        }
    }
}

public enum QueryResultStatus: String, Sendable, Codable {
    case ok = "OK"
    case err = "ERR"
}

public struct RPCQueryResult: Sendable, Codable {
    public let status: QueryResultStatus
    public let time: String
    public let result: SurrealValue
    public let type: String?
    public let kind: String?
    public let details: SurrealValue?
}

public enum LiveAction: String, Sendable, Codable {
    case create = "CREATE"
    case update = "UPDATE"
    case delete = "DELETE"
    case killed = "KILLED"
}

public struct LiveEvent<T: Decodable & Sendable>: Sendable {
    public let queryID: UUID
    public let action: LiveAction
    public let recordID: String
    public let rawPayload: SurrealValue
    public let decoded: T?

    public init(
        queryID: UUID,
        action: LiveAction,
        recordID: String,
        rawPayload: SurrealValue,
        decoded: T?
    ) {
        self.queryID = queryID
        self.action = action
        self.recordID = recordID
        self.rawPayload = rawPayload
        self.decoded = decoded
    }
}
