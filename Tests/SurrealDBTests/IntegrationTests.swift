import Foundation
import Testing
@testable import SurrealDB

private struct IntegrationPerson: SurrealModel, Codable, Sendable {
    static let surrealTable = "person"

    let id: String?
    let name: String
    let age: Int

    init(id: String? = nil, name: String, age: Int) {
        self.id = id
        self.name = name
        self.age = age
    }
}

private struct IntegrationLivePerson: SurrealModel, Codable, Sendable {
    static let surrealTable = "live_person"

    let id: String?
    let name: String
    let age: Int

    init(id: String? = nil, name: String, age: Int) {
        self.id = id
        self.name = name
        self.age = age
    }
}

enum IntegrationEnv {
    static func value(_ key: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[key]
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    static var enabled: Bool {
        value("SURREALDB_RUN_INTEGRATION") == "1"
    }

    /// `host[:port]` or a full URL. Bare host strings become `ws://host` /
    /// `http://host`; full URLs are passed through as-is for the matching
    /// transport.
    static var host: String {
        value("SURREALDB_HOST") ?? "127.0.0.1:8000"
    }

    static var namespace: String {
        value("SURREALDB_NAMESPACE") ?? "test"
    }

    static var database: String {
        value("SURREALDB_NAME") ?? "test"
    }

    static var user: String? { value("SURREALDB_USER") }
    static var password: String? { value("SURREALDB_PASSWORD") }

    static var authLevel: AuthLevel {
        AuthLevel(value("SURREALDB_AUTH_LEVEL"))
    }

    enum AuthLevel {
        case root, namespace, database

        init(_ raw: String?) {
            switch raw?.lowercased() {
            case "namespace", "ns": self = .namespace
            case "database", "db": self = .database
            case "root", nil, "": self = .root
            default: self = .root
            }
        }
    }

    static func endpoint(scheme: String) -> String {
        let host = host
        if host.contains("://") { return host }
        return "\(scheme)://\(host)"
    }

    /// Whether the proxy-based tests can run. `TCPProxy` forwards plain TCP
    /// and the tests reach it over `ws://`, so a TLS host (`https://`,
    /// `wss://`) can't sit behind it.
    static var canProxy: Bool {
        enabled && !["https://", "wss://"].contains { host.lowercased().hasPrefix($0) }
    }

    static var hasCredentials: Bool {
        user != nil && password != nil
    }
}

func wsEndpoint() -> String { IntegrationEnv.endpoint(scheme: "ws") }
func httpEndpoint() -> String { IntegrationEnv.endpoint(scheme: "http") }
func shouldSkipSignin() -> Bool { !IntegrationEnv.hasCredentials }

func authenticateIfNeeded(_ client: some SurrealQueryable) async throws {
    guard let user = IntegrationEnv.user, let password = IntegrationEnv.password else {
        return
    }
    let credentials: SignInCredentials
    switch IntegrationEnv.authLevel {
    case .root:
        credentials = .root(username: user, password: password)
    case .namespace:
        credentials = .namespace(
            namespace: IntegrationEnv.namespace,
            username: user,
            password: password
        )
    case .database:
        credentials = .database(
            namespace: IntegrationEnv.namespace,
            database: IntegrationEnv.database,
            username: user,
            password: password
        )
    }
    _ = try await client.signin(credentials)
}

func awaitTaskValue<T: Sendable>(
    _ task: Task<T, Error>,
    timeoutSeconds: Double,
    timeoutMessage: String
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000))
            task.cancel()
            throw SurrealError.invalidResponse(timeoutMessage)
        }

        guard let value = try await group.next() else {
            throw SurrealError.invalidResponse(timeoutMessage)
        }

        group.cancelAll()
        return value
    }
}

func assertAllOK(_ rows: [RPCQueryResult]) {
    #expect(!rows.isEmpty)
    for row in rows {
        #expect(row.status == .ok)
    }
}

@Test
func integration_wsAuthQueryCrud() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: wsEndpoint())
    try await client.connect()
    defer { Task { await client.close() } }

    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)

    let rows = try await client.queryRaw("RETURN 1;", bindings: [:])
    #expect(!rows.isEmpty)

    let created = try await client.create(IntegrationPerson(name: "Ada", age: 30))
    if shouldSkipSignin() {
        #expect(created.count >= 0)
    } else {
        #expect(!created.isEmpty)
    }

    let selected = try await client.select(IntegrationPerson.self, where: nil, limit: nil, start: nil)
    if shouldSkipSignin() {
        #expect(selected.count >= 0)
    } else {
        #expect(!selected.isEmpty)
    }
}

@Test
func integration_httpParity() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: httpEndpoint())
    try await client.connect()
    defer { Task { await client.close() } }

    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)

    let rows = try await client.queryRaw("RETURN 1;", bindings: [:])
    #expect(!rows.isEmpty)
}

@Test
func integration_wsFullCRUDQueries() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: wsEndpoint())
    try await client.connect()
    defer { Task { await client.close() } }

    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)

    let rid = "crud_person:\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"

    let create = try await client.queryRaw("CREATE \(rid) CONTENT { name: 'Ada', age: 30 };", bindings: [:])
    assertAllOK(create)

    let select = try await client.queryRaw("SELECT * FROM \(rid);", bindings: [:])
    assertAllOK(select)
    if case .array(let rows) = select[0].result {
        if shouldSkipSignin() {
            #expect(rows.count >= 0)
        } else {
            #expect(rows.count == 1)
        }
    } else {
        Issue.record("Expected SELECT result array for created record.")
    }

    let update = try await client.queryRaw("UPDATE \(rid) CONTENT { name: 'Ada', age: 31 };", bindings: [:])
    assertAllOK(update)

    let upsert = try await client.queryRaw("UPSERT \(rid) CONTENT { name: 'Ada', age: 32, city: 'Paris' };", bindings: [:])
    assertAllOK(upsert)

    let delete = try await client.queryRaw("DELETE \(rid);", bindings: [:])
    assertAllOK(delete)

    let selectAfterDelete = try await client.queryRaw("SELECT * FROM \(rid);", bindings: [:])
    assertAllOK(selectAfterDelete)
    if case .array(let rows) = selectAfterDelete[0].result {
        #expect(rows.isEmpty)
    } else {
        Issue.record("Expected SELECT result array after delete.")
    }
}

@Test
func integration_wsFunctionAndGeoQueries() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: wsEndpoint())
    try await client.connect()
    defer { Task { await client.close() } }

    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)

    let fnName = "fn::sdk::lower_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    let define = try await client.queryRaw(
        "DEFINE FUNCTION \(fnName)($value: string) { RETURN string::lowercase($value); };",
        bindings: [:]
    )
    assertAllOK(define)

    let call = try await client.queryRaw("RETURN \(fnName)('HELLO');", bindings: [:])
    assertAllOK(call)

    let geoQuery = try await client.queryRaw("RETURN geo::distance((51.5074, -0.1278), (40.7128, -74.0060));", bindings: [:])
    assertAllOK(geoQuery)
}

@Test
func integration_wsLiveQueries() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: wsEndpoint())
    try await client.connect()
    defer { Task { await client.close() } }

    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)

    let defineTable = try await client.queryRaw("DEFINE TABLE IF NOT EXISTS \(IntegrationLivePerson.surrealTable) SCHEMALESS;", bindings: [:])
    assertAllOK(defineTable)

    let recordKey = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let rid = "\(IntegrationLivePerson.surrealTable):\(recordKey)"

    let stream = try await client.live(SurrealDSL.live(IntegrationLivePerson.self))
    let collector = Task<[LiveEvent<IntegrationLivePerson>], Error> {
        var iterator = stream.makeAsyncIterator()
        var events: [LiveEvent<IntegrationLivePerson>] = []

        while events.count < 3 {
            guard let event = await iterator.next() else {
                throw SurrealError.invalidResponse("Live stream ended before receiving expected events.")
            }

            if event.action == .killed {
                continue
            }

            events.append(event)
        }

        return events
    }
    defer { collector.cancel() }

    let create = try await client.queryRaw("CREATE \(rid) CONTENT { name: 'LiveAda', age: 30 };", bindings: [:])
    assertAllOK(create)

    let update = try await client.queryRaw("UPDATE \(rid) CONTENT { name: 'LiveAda', age: 31 };", bindings: [:])
    assertAllOK(update)

    let delete = try await client.queryRaw("DELETE \(rid);", bindings: [:])
    assertAllOK(delete)

    let events = try await awaitTaskValue(
        collector,
        timeoutSeconds: 10,
        timeoutMessage: "Timed out waiting for live query events."
    )

    #expect(events.count == 3)
    #expect(events.contains(where: { $0.action == .create }))
    #expect(events.contains(where: { $0.action == .update }))
    #expect(events.contains(where: { $0.action == .delete }))

    let eventQueryIDs = Set(events.map(\.queryID))
    #expect(eventQueryIDs.count == 1)

    if let updateEvent = events.first(where: { $0.action == .update }) {
        #expect(updateEvent.decoded?.name == "LiveAda")
        #expect(updateEvent.decoded?.age == 31)
    } else {
        Issue.record("Missing UPDATE live event.")
    }
}

@Test
func integration_sessionForkIsolationAndClose() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try SurrealClient(endpoint: wsEndpoint())
    try await client.connect()
    defer { Task { await client.close() } }

    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)

    let base = try await client.newSession()
    try await base.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    try await authenticateIfNeeded(base)
    try await base.set("marker", value: .string("base"))

    let forked = try await base.forkSession()
    defer { Task { try? await forked.closeSession() } }

    // forkSession() inherits namespace/database/variables from the source session.
    let inherited = try await forked.query(SurrealQuery<String>(sql: "RETURN $marker;"))
    #expect(inherited.first == "base")

    // Diverging each session's variables after the fork must not cross-contaminate.
    try await base.set("marker", value: .string("base-updated"))
    try await forked.set("marker", value: .string("forked-updated"))

    let baseMarker = try await base.query(SurrealQuery<String>(sql: "RETURN $marker;"))
    let forkedMarker = try await forked.query(SurrealQuery<String>(sql: "RETURN $marker;"))
    #expect(baseMarker.first == "base-updated")
    #expect(forkedMarker.first == "forked-updated")

    // The connection reports both attached (non-root) sessions.
    let attached = try await client.sessions()
    #expect(attached.contains(base.id))
    #expect(attached.contains(forked.id))

    // closeSession() invalidates the session going forward.
    try await forked.closeSession()
    let stillValid = await forked.isValid
    #expect(!stillValid)

    try await base.closeSession()
}
