import Foundation
import SurrealConformance
import SurrealDB

// A driver for surrealdb-protocol's conformance runner: reads one JSON
// request per line on stdin and answers one per line on stdout, mapping each
// op onto this SDK's public API. See conformance/README.md in
// surrealdb-protocol for the protocol and the ops.
//
// The scenarios expect SurrealDB 4.0's sized numbers widened, as plain cbor
// carries them, so the driver doesn't offer cbor.2 unless
// SURREALDB_CONFORMANCE_CBOR2=1.

struct DriverError: Error {
    let kind: String
    let message: String
    var details: SurrealValue?
    var code: Int?
    var failures: [DriverError] = []

    static func unsupported(_ message: String) -> DriverError {
        DriverError(kind: "Unsupported", message: message)
    }

    static func bad(_ message: String) -> DriverError {
        DriverError(kind: "Protocol", message: message)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind), "message": .string(message)]
        if let details { object["details"] = TypedJSON.json(from: details) }
        if let code { object["code"] = .integer(String(code)) }
        if !failures.isEmpty { object["failures"] = .array(failures.map(\.json)) }
        return .object(object)
    }

    /// How this SDK reports a failure, as the runner wants it: the server's
    /// kind and details, not its message text.
    init(_ error: any Error) {
        switch error {
        case let error as DriverError:
            self = error
        case SurrealError.serverError(let object):
            self.init(kind: object.kind ?? "Internal", message: object.message, details: object.details, code: object.code)
        case SurrealError.queryErrors(let errors) where errors.count == 1:
            self.init(errors[0])
        case SurrealError.importFailed(let errors):
            self.init(kind: "Query", message: SurrealError.importFailed(errors).message, failures: errors.map(DriverError.init))
        case SurrealError.unsupportedFeature(let message):
            self.init(kind: "Unsupported", message: message)
        case let error as SurrealError:
            self.init(kind: "Connection", message: error.message)
        default:
            self.init(kind: "Internal", message: "\(error)")
        }
    }

    init(_ detail: QueryErrorDetail) {
        self.init(kind: detail.kind ?? "Internal", message: detail.message, details: detail.details)
    }

    init(kind: String, message: String, details: SurrealValue? = nil, code: Int? = nil, failures: [DriverError] = []) {
        self.kind = kind
        self.message = message
        self.details = details
        self.code = code
        self.failures = failures
    }
}

/// Buffers a live stream's events so `next_notification` can wait on them
/// with a timeout.
final class Subscription: @unchecked Sendable {
    let queryID: UUID
    let session: String?
    private let lock = NSLock()
    private var events: [LiveEvent<SurrealValue>] = []
    private var pump: Task<Void, Never>?

    init(queryID: UUID, session: String?, stream: AsyncStream<LiveEvent<SurrealValue>>) {
        self.queryID = queryID
        self.session = session
        pump = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    private func append(_ event: LiveEvent<SurrealValue>) {
        lock.withLock { events.append(event) }
    }

    func next(timeout: TimeInterval) async -> LiveEvent<SurrealValue>? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let event: LiveEvent<SurrealValue>? = lock.withLock { events.isEmpty ? nil : events.removeFirst() }
            if let event { return event }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func cancel() {
        pump?.cancel()
    }
}

final class Driver {
    private var client: SurrealClient?
    private var transport = "ws"
    private var sessions: [String: SurrealSession] = [:]
    private var transactions: [String: (transaction: SurrealInteractiveTransaction, session: String?)] = [:]
    private var subscriptions: [String: Subscription] = [:]
    private var nextHandle = 1

    private static let ops = [
        "connect", "close", "version", "signin", "signup", "authenticate", "invalidate", "info", "use", "set",
        "unset", "query", "run", "live", "live_of", "live_id", "next_notification", "kill", "new_session",
        "fork_session", "list_sessions", "close_session", "begin", "commit", "cancel", "import", "export"
    ]

    private func handle(_ prefix: String) -> String {
        defer { nextHandle += 1 }
        return "\(prefix)-\(nextHandle)"
    }

    func call(_ op: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        switch op {
        case "hello":
            return .object([
                "name": .string("surrealdb.swift"),
                "version": .string("main"),
                "ops": .array(Self.ops.map(JSONValue.string))
            ])
        case "connect":
            guard case .string(let url)? = args["url"] else { throw DriverError.bad("connect needs url") }
            if case .string(let transport)? = args["transport"] { self.transport = transport }
            await close()
            let offersCBOR2 = ProcessInfo.processInfo.environment["SURREALDB_CONFORMANCE_CBOR2"] == "1"
            let client = try SurrealClient(
                endpoint: url,
                options: .init(negotiatesCBOR2: offersCBOR2),
                websocketOptions: .init(reconnectEnabled: false)
            )
            try await client.connect()
            self.client = client
            return .null
        case "close":
            await close()
            return .null
        case "version":
            // The SDK drops the server's `surrealdb-` prefix; the runner
            // wants the string as the server sends it.
            return .string("surrealdb-" + (try await connected().version()))
        case "ping":
            throw DriverError.unsupported("The SDK has no ping.")
        case "signin":
            let tokens = try await scope(args).signin(signInCredentials(args["credentials"]))
            return token(tokens)
        case "signup":
            let tokens = try await scope(args).signup(signUpCredentials(args["credentials"]))
            return token(tokens)
        case "authenticate":
            switch args["token"] {
            case .string(let token)?:
                try await scope(args).authenticate(token)
            case .object(let fields)?:
                guard case .string(let access)? = fields["access"] else { throw DriverError.bad("authenticate needs a token") }
                var refresh: String?
                if case .string(let value)? = fields["refresh"] { refresh = value }
                _ = try await scope(args).authenticate(AuthTokens(access: access, refresh: refresh))
            default:
                throw DriverError.bad("authenticate needs a token")
            }
            return .null
        case "invalidate":
            try await scope(args).invalidate()
            return .null
        case "info":
            return TypedJSON.json(from: try await scope(args).info())
        case "use":
            let namespace = optionalString(args["namespace"])
            let database = optionalString(args["database"])
            try await scope(args).use(namespace: namespace, database: database)
            return .object([
                "namespace": namespace.map(JSONValue.string) ?? .null,
                "database": database.map(JSONValue.string) ?? .null
            ])
        case "set":
            guard case .string(let name)? = args["name"] else { throw DriverError.bad("set needs a name") }
            try await scope(args).set(name, value: TypedJSON.value(from: args["value"] ?? .null))
            return .null
        case "unset":
            guard case .string(let name)? = args["name"] else { throw DriverError.bad("unset needs a name") }
            try await scope(args).unset(name)
            return .null
        case "query":
            guard case .string(let sql)? = args["sql"] else { throw DriverError.bad("query needs sql") }
            let bindings = try variables(args["vars"])
            let results: [RPCQueryResult]
            if let transaction = try transaction(args) {
                results = try await transaction.queryRaw(sql, bindings: bindings)
            } else {
                results = try await scope(args).queryRaw(sql, bindings: bindings)
            }
            return .array(results.map { result in
                if result.status == .ok {
                    return .object(["ok": .bool(true), "result": TypedJSON.json(from: result.result)])
                }
                var message = "\(result.result)"
                if case .string(let text) = result.result { message = text }
                let error = DriverError(kind: result.kind ?? "Internal", message: message, details: result.details)
                return .object(["ok": .bool(false), "error": error.json])
            })
        case "query_stream":
            throw DriverError.unsupported("The SDK has no streamed query results.")
        case "run":
            guard case .string(let name)? = args["name"] else { throw DriverError.bad("run needs a name") }
            var arguments: [SurrealValue] = []
            if case .array(let values)? = args["args"] { arguments = try values.map(TypedJSON.value(from:)) }
            let value = try await withScope(args) { client in
                try await client.run(name, version: self.optionalString(args["version"]), arguments: arguments)
            } session: { session in
                try await session.run(name, version: self.optionalString(args["version"]), arguments: arguments)
            }
            return TypedJSON.json(from: value)
        case "live":
            guard case .string(let table)? = args["table"] else { throw DriverError.bad("live needs a table") }
            let diff = args["diff"] == .bool(true)
            // `live()` doesn't hand out the query id, which `live_id` needs,
            // so start it with LIVE SELECT and stream it with `liveOf`.
            let sql = "LIVE SELECT \(diff ? "DIFF" : "*") FROM \(SurrealQL.escapeIdent(table))"
            let results = try await scope(args).queryRaw(sql, bindings: [:])
            guard let result = results.first else { throw DriverError(kind: "Internal", message: "LIVE SELECT gave no result.") }
            guard result.status == .ok, case .uuid(let id) = result.result else {
                throw DriverError(kind: result.kind ?? "Internal", message: "\(result.result)", details: result.details)
            }
            return try await subscribe(id, args)
        case "live_of":
            guard case .object(let fields)? = args["id"], case .string(let text)? = fields["$uuid"], let id = UUID(uuidString: text) else {
                throw DriverError.bad("live_of needs a $uuid id")
            }
            return try await subscribe(id, args)
        case "live_id":
            let subscription = try self.subscription(args)
            return .object(["$uuid": .string(subscription.queryID.uuidString.lowercased())])
        case "next_notification":
            let subscription = try self.subscription(args)
            var timeout = 5.0
            if case .integer(let text)? = args["timeout"], let ms = Double(text) { timeout = ms / 1000 }
            guard let event = await subscription.next(timeout: timeout) else { return .null }
            if event.action == .killed { return .object(["action": .string("KILLED")]) }
            return .object([
                "action": .string(event.action.rawValue),
                "record": event.record.map { TypedJSON.json(from: .recordID($0)) } ?? .null,
                "result": TypedJSON.json(from: event.rawPayload)
            ])
        case "kill":
            let subscription = try self.subscription(args)
            try await scope(args).kill(liveQueryID: subscription.queryID)
            return .null
        case "new_session":
            let session = try await connected().newSession()
            let handle = handle("session")
            sessions[handle] = session
            return .string(handle)
        case "fork_session":
            guard let from = optionalString(args["from"]) else {
                throw DriverError.unsupported("The SDK forks attached sessions, not the default one.")
            }
            let session = try await self.session(from).forkSession()
            let handle = handle("session")
            sessions[handle] = session
            return .string(handle)
        case "list_sessions":
            let open = try await connected().sessions()
            var handles: [JSONValue] = []
            for id in open {
                if let handle = sessions.first(where: { $0.value.id == id })?.key {
                    handles.append(.string(handle))
                } else {
                    let handle = handle("session")
                    sessions[handle] = try await connected().session(id: id)
                    handles.append(.string(handle))
                }
            }
            return .array(handles)
        case "close_session":
            guard let handle = optionalString(args["session"]) else { throw DriverError.bad("close_session needs a session") }
            try await session(handle).closeSession()
            sessions[handle] = nil
            return .null
        case "begin":
            guard args["txn"] == nil else { throw DriverError.unsupported("Transactions don't nest.") }
            let transaction = try await withScope(args) { try await $0.beginTransaction() } session: { try await $0.beginTransaction() }
            let handle = handle("txn")
            transactions[handle] = (transaction, optionalString(args["session"]))
            return .string(handle)
        case "commit", "cancel":
            guard let transaction = try transaction(args) else { throw DriverError.bad("\(op) needs a txn") }
            // The handle stays: using it afterwards is the server's to refuse.
            if op == "commit" { try await transaction.commit() } else { try await transaction.cancel() }
            return .null
        case "import":
            guard case .string(let surql)? = args["surql"] else { throw DriverError.bad("import needs surql") }
            try await withScope(args) { try await $0.import(surql) } session: { try await $0.import(surql) }
            return .null
        case "export":
            let options = try exportOptions(args["options"])
            let text = try await withScope(args) { try await $0.export(options) } session: { try await $0.export(options) }
            return .string(text)
        case "raw_rpc", "raw_http":
            throw DriverError.unsupported("\(op) is for the reference adapter.")
        default:
            throw DriverError.unsupported("Unknown op \(op).")
        }
    }

    func close() async {
        for subscription in subscriptions.values { subscription.cancel() }
        subscriptions = [:]
        sessions = [:]
        transactions = [:]
        await client?.close()
        client = nil
    }

    // MARK: - Scope

    private func connected() throws -> SurrealClient {
        guard let client else { throw DriverError(kind: "Connection", message: "Not connected.") }
        return client
    }

    private func session(_ handle: String) throws -> SurrealSession {
        guard let session = sessions[handle] else { throw DriverError.bad("Unknown session \(handle).") }
        return session
    }

    /// The session the op names, or the client (its default session). An op
    /// that only sessions and the client have can't run in a transaction,
    /// so a `txn` is refused rather than ignored.
    private func scope(_ args: [String: JSONValue]) throws -> any SurrealLiveQueryable {
        guard args["txn"] == nil else { throw DriverError.unsupported("This op can't run inside a transaction.") }
        if let handle = optionalString(args["session"]) { return try session(handle) }
        return try connected()
    }

    private func withScope<T>(
        _ args: [String: JSONValue],
        client: (SurrealClient) async throws -> T,
        session: (SurrealSession) async throws -> T
    ) async throws -> T {
        guard args["txn"] == nil else { throw DriverError.unsupported("This op can't run inside a transaction.") }
        if let handle = optionalString(args["session"]) { return try await session(self.session(handle)) }
        return try await client(connected())
    }

    private func transaction(_ args: [String: JSONValue]) throws -> SurrealInteractiveTransaction? {
        guard let handle = optionalString(args["txn"]) else { return nil }
        guard let entry = transactions[handle] else { throw DriverError.bad("Unknown transaction \(handle).") }
        // A transaction belongs to the session it was begun in.
        guard entry.session == optionalString(args["session"]) else {
            throw DriverError(kind: "Validation", message: "Transaction \(handle) belongs to another session.")
        }
        return entry.transaction
    }

    private func subscription(_ args: [String: JSONValue]) throws -> Subscription {
        guard let handle = optionalString(args["subscription"]), let subscription = subscriptions[handle] else {
            throw DriverError.bad("Unknown subscription.")
        }
        return subscription
    }

    private func subscribe(_ id: UUID, _ args: [String: JSONValue]) async throws -> JSONValue {
        let stream = try await scope(args).liveOf(id, as: SurrealValue.self)
        let handle = handle("live")
        subscriptions[handle] = Subscription(queryID: id, session: optionalString(args["session"]), stream: stream)
        return .string(handle)
    }

    // MARK: - Arguments

    private func optionalString(_ json: JSONValue?) -> String? {
        if case .string(let value)? = json { return value }
        return nil
    }

    private func variables(_ json: JSONValue?) throws -> [String: SurrealValue] {
        guard let json, json != .null else { return [:] }
        guard case .object(let value) = try TypedJSON.value(from: json) else { throw DriverError.bad("vars must be an object") }
        return value
    }

    private func token(_ tokens: AuthTokens) -> JSONValue {
        guard let refresh = tokens.refresh else { return .string(tokens.access) }
        return .object(["access": .string(tokens.access), "refresh": .string(refresh)])
    }

    /// The RPC wire keys: `user` and `pass` for a system user, `key` for
    /// bearer access, and otherwise record access, where every key but `ns`,
    /// `db` and `ac` is a variable.
    private func signInCredentials(_ json: JSONValue?) throws -> SignInCredentials {
        guard case .object(var fields)? = try json.map(TypedJSON.value(from:)) else { throw DriverError.bad("credentials must be an object") }
        func take(_ key: String) -> String? {
            guard case .string(let value)? = fields.removeValue(forKey: key) else { return nil }
            return value
        }
        let namespace = take("ns")
        let database = take("db")
        if fields["user"] != nil {
            let user = take("user") ?? ""
            let pass = take("pass") ?? ""
            switch (namespace, database) {
            case let (namespace?, database?): return .database(namespace: namespace, database: database, username: user, password: pass)
            case let (namespace?, nil): return .namespace(namespace: namespace, username: user, password: pass)
            default: return .root(username: user, password: pass)
            }
        }
        guard let access = take("ac") else { throw DriverError.bad("record and bearer access need ac") }
        if let key = take("key") {
            return .accessBearer(namespace: namespace, database: database, access: access, key: key)
        }
        return .accessVariables(namespace: namespace, database: database, access: access, variables: fields)
    }

    private func signUpCredentials(_ json: JSONValue?) throws -> SignUpCredentials {
        guard case .object(var fields)? = try json.map(TypedJSON.value(from:)) else { throw DriverError.bad("credentials must be an object") }
        func take(_ key: String) -> String? {
            guard case .string(let value)? = fields.removeValue(forKey: key) else { return nil }
            return value
        }
        let namespace = take("ns")
        let database = take("db")
        guard let access = take("ac") else { throw DriverError.bad("signup needs ac") }
        return .accessRecord(namespace: namespace, database: database, access: access, variables: fields)
    }

    /// The `/export` body: booleans per kind, and `tables` as a boolean or a
    /// list of names.
    private func exportOptions(_ json: JSONValue?) throws -> SurrealExportOptions? {
        guard case .object(let fields)? = json else { return nil }
        func flag(_ key: String) -> Bool? {
            if case .bool(let value)? = fields[key] { return value }
            return nil
        }
        var options = SurrealExportOptions(
            records: flag("records"), users: flag("users"), accesses: flag("accesses"), params: flag("params"),
            functions: flag("functions"), analyzers: flag("analyzers"), sequences: flag("sequences"), apis: flag("apis"),
            buckets: flag("buckets")
        )
        switch fields["tables"] {
        case .bool(true)?: options.tables = .all
        case .bool(false)?: options.tables = .noTables
        case .array(let names)?: options.tables = .only(names.compactMap(optionalString))
        case nil: break
        default: throw DriverError.unsupported("This form of export tables.")
        }
        return options
    }
}

// MARK: - The JSON-lines loop

func write(_ line: JSONValue) {
    FileHandle.standardOutput.write(Data((line.serialized + "\n").utf8))
}

let driver = Driver()
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    var id: JSONValue = .null
    do {
        guard case .object(let request) = try JSONValue.parse(line), let requestID = request["id"], case .string(let op)? = request["op"] else {
            throw DriverError.bad("A request is {id, op, args}.")
        }
        id = requestID
        var args: [String: JSONValue] = [:]
        if case .object(let fields)? = request["args"] { args = fields }
        let result = try await driver.call(op, args)
        write(.object(["id": id, "ok": .bool(true), "result": result]))
    } catch {
        write(.object(["id": id, "ok": .bool(false), "error": DriverError(error).json]))
    }
}
await driver.close()
exit(0)
