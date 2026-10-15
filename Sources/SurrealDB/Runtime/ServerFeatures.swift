import Foundation

extension RPCQueryResult {
    /// The server's message for a failed statement.
    var errorMessage: String {
        if case .string(let message) = result {
            return message
        }
        return "Unknown query error"
    }
}

/// What `export(_:)` includes. Leave a field `nil` to use the server's
/// default, which includes everything.
public struct SurrealExportOptions: Sendable, Hashable {
    /// Which tables to export, definitions and records.
    public enum Tables: Sendable, Hashable {
        case all
        case none
        case only([String])
        case excluding([String])
    }

    public var tables: Tables?
    /// Table records, as opposed to just their definitions.
    public var records: Bool?
    public var users: Bool?
    public var accesses: Bool?
    public var params: Bool?
    public var functions: Bool?
    public var analyzers: Bool?
    public var versions: Bool?
    public var sequences: Bool?
    public var apis: Bool?
    public var buckets: Bool?

    public init(
        tables: Tables? = nil,
        records: Bool? = nil,
        users: Bool? = nil,
        accesses: Bool? = nil,
        params: Bool? = nil,
        functions: Bool? = nil,
        analyzers: Bool? = nil,
        versions: Bool? = nil,
        sequences: Bool? = nil,
        apis: Bool? = nil,
        buckets: Bool? = nil
    ) {
        self.tables = tables
        self.records = records
        self.users = users
        self.accesses = accesses
        self.params = params
        self.functions = functions
        self.analyzers = analyzers
        self.versions = versions
        self.sequences = sequences
        self.apis = apis
        self.buckets = buckets
    }

    /// The body `POST /export` takes. Fields left `nil` are omitted, so the
    /// server's default applies.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        switch tables {
        case .all?: object["tables"] = true
        case .none?: object["tables"] = false
        case .only(let names)?: object["tables"] = names
        case .excluding(let names)?: object["tables"] = ["exclude": names]
        case nil: break
        }
        let flags: [(String, Bool?)] = [
            ("records", records), ("users", users), ("accesses", accesses), ("params", params),
            ("functions", functions), ("analyzers", analyzers), ("versions", versions),
            ("sequences", sequences), ("apis", apis), ("buckets", buckets),
        ]
        for (key, value) in flags {
            if let value { object[key] = value }
        }
        return object
    }
}

/// An HTTP method for a `DEFINE API` endpoint.
public enum SurrealAPIMethod: String, Sendable, Hashable, CaseIterable {
    case get, post, put, patch, delete, trace
}

/// The response from a `DEFINE API` endpoint called with `api(_:)`.
public struct SurrealAPIResponse: Sendable, Hashable {
    public let status: Int
    public let headers: [String: String]
    public let body: SurrealValue

    public init(status: Int, headers: [String: String], body: SurrealValue) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Decodes `body` as `T`.
    public func body<T: Decodable>(as type: T.Type) throws -> T {
        try body.decode(type)
    }

    init(_ value: SurrealValue) throws {
        guard case .object(let object) = value else {
            throw SurrealError.invalidResponse("Expected an API response object, got \(value.kindName).")
        }
        switch object["status"] {
        case .int(let code)?:
            status = Int(code)
        default:
            throw SurrealError.invalidResponse("Expected a status in the API response.")
        }
        var headers: [String: String] = [:]
        if case .object(let raw)? = object["headers"] {
            for (key, value) in raw {
                if case .string(let text) = value { headers[key] = text }
            }
        }
        self.headers = headers
        body = object["body"] ?? .none
    }
}

extension SurrealClientCore {
    /// Calls a server-side function by name (`run`), such as `fn::greet` or
    /// `string::len`.
    func run(_ name: String, version: String?, arguments: [SurrealValue], session: SessionID?) async throws -> SurrealValue {
        try await rpc("run", params: [.string(name), version.map(SurrealValue.string) ?? .none, .array(arguments)], session: session)
    }

    /// Calls a `DEFINE API` endpoint through `api::invoke`, which works over
    /// both transports.
    func api(
        _ path: String,
        method: SurrealAPIMethod,
        body: SurrealValue?,
        headers: [String: String],
        query: [String: String],
        session: SessionID?
    ) async throws -> SurrealAPIResponse {
        var request: [String: SurrealValue] = [
            "method": .string(method.rawValue),
            "headers": .object(headers.mapValues(SurrealValue.string)),
            "query": .object(query.mapValues(SurrealValue.string)),
        ]
        if let body {
            request["body"] = body
        }
        let results = try await queryRaw(
            "RETURN api::invoke($_sdk_path, $_sdk_request);",
            bindings: ["_sdk_path": .string(path), "_sdk_request": .object(request)],
            session: session
        )
        guard let row = results.first else {
            throw SurrealError.invalidResponse("Expected a result from api::invoke.")
        }
        guard row.status == .ok else {
            throw SurrealError.queryErrors([QueryErrorDetail(index: 0, message: row.errorMessage, kind: row.kind, details: row.details)])
        }
        return try SurrealAPIResponse(row.result)
    }

    func importSQL(_ sql: String, session: SessionID?) async throws {
        guard let http else {
            throw SurrealError.unsupportedFeature("import needs the server's HTTP endpoint.")
        }
        // These go straight to URLSession, so check the client is connected
        // as the RPC engines do.
        guard isConnected else {
            throw SurrealError.notConnected
        }
        try await http.importSQL(sql, session: sessionContext(for: session))
    }

    func export(_ options: SurrealExportOptions?, session: SessionID?) async throws -> String {
        guard let http else {
            throw SurrealError.unsupportedFeature("export needs the server's HTTP endpoint.")
        }
        // These go straight to URLSession, so check the client is connected
        // as the RPC engines do.
        guard isConnected else {
            throw SurrealError.notConnected
        }
        return try await http.export(options, session: sessionContext(for: session))
    }
}
