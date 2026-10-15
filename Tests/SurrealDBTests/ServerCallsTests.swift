import Foundation
import Testing
@testable import SurrealDB

@Test
func serverVersion_rangeIsMinimumUpToButNotIncluding5() {
    #expect(ServerVersion.isSupported("3.0.0"))
    #expect(ServerVersion.isSupported("surrealdb-3.3.4"))
    #expect(ServerVersion.isSupported("3.4.0-nightly+20261014.4f7fa16"))
    #expect(ServerVersion.isSupported("4.0.0"))
    #expect(ServerVersion.isSupported("4.99.99"))
    #expect(!ServerVersion.isSupported("2.6.2"))
    #expect(!ServerVersion.isSupported("5.0.0"))
    #expect(!ServerVersion.isSupported("5.0.0-alpha.1"))
    #expect(!ServerVersion.isSupported("not a version"))
}

@Test
func health_failsAgainstDeadHost() async throws {
    let client = try SurrealClient(endpoint: "http://127.0.0.1:1")
    await #expect(throws: SurrealError.self) {
        try await client.health()
    }
}

@Test
func integration_versionAndHealth() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        // checkServerVersion is on by default, so connecting at all means
        // the server passed the range check.
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        let version = try await client.version()
        #expect(!version.hasPrefix("surrealdb-"))
        #expect(ServerVersion.isSupported(version))
        try await client.health()
    }
}

@Test
func integration_letAndUnsetAreServerSideAndSurviveReconnect() async throws {
    guard IntegrationEnv.canProxy else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        try await client.set("answer", value: .int(42))
        #expect(try await client.queryRaw("RETURN $answer;").first?.result == .int(42))
        try await client.unset("answer")
        #expect(try await client.queryRaw("RETURN $answer;").first?.result == SurrealValue.none)
    }

    // Over WebSocket the variable lives on the server, and is put back after
    // a reconnect.
    let proxy = TCPProxy(upstream: IntegrationEnv.host)
    try await proxy.start()
    defer { proxy.shutdown() }
    let client = try await integrationClient("ws://127.0.0.1:\(proxy.port)", websocketOptions: .init(reconnectBaseDelay: 0.05))
    defer { Task { await client.close() } }

    try await client.set("answer", value: .string("kept"))
    // `LET`-defined parameters are visible to SurrealQL that never sees our
    // bindings, such as a function body.
    _ = try await client.queryRaw("DEFINE FUNCTION fn::answer() { RETURN $answer; };")
    #expect(try await client.queryRaw("RETURN fn::answer();").first?.result == .string("kept"))

    proxy.dropConnections()
    let replayed = await eventually {
        (try? await client.queryRaw("RETURN $answer;").first?.result) == .string("kept")
    }
    #expect(replayed)
}

@Test
func integration_resetClearsTheSession() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        try await client.set("x", value: .int(1))
        try await client.reset()
        // Signed out with no namespace: the server refuses the query, as an
        // RPC error over WebSocket and an ERR result over HTTP.
        var refused = false
        do {
            refused = try await client.queryRaw("RETURN 1;").first?.status == .err
        } catch {
            refused = true
        }
        #expect(refused)
        // Signed out too, and $x is gone.
        try await authenticateIfNeeded(client)
        try await client.use(namespace: IntegrationEnv.namespace, database: "test")
        #expect(try await client.queryRaw("RETURN $x;").first?.result == SurrealValue.none)
    }
}

private struct AppUser: Codable, Sendable {
    let id: SurrealRecordID
    let email: String
}

@Test
func integration_infoRefreshAndRevoke() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let admin = try await integrationClient(endpoint)
        defer { Task { await admin.close() } }
        let scope = try #require(try await admin.queryRaw("RETURN [session::ns(), session::db()];").first?.result)
        guard case .array(let parts) = scope, case .string(let ns) = parts[0], case .string(let db) = parts[1] else {
            Issue.record("Expected ns/db")
            return
        }
        _ = try await admin.queryRaw("""
            DEFINE ACCESS account ON DATABASE TYPE RECORD
                SIGNUP ( CREATE user SET email = $email, pass = crypto::argon2::generate($pass) )
                SIGNIN ( SELECT * FROM user WHERE email = $email AND crypto::argon2::compare(pass, $pass) )
                WITH REFRESH
                DURATION FOR GRANT 1d, FOR TOKEN 2s, FOR SESSION 1h;
            DEFINE TABLE user PERMISSIONS FOR select WHERE id = $auth.id;
            """)

        let client = try SurrealClient(endpoint: endpoint)
        try await client.connect()
        defer { Task { await client.close() } }
        try await client.use(namespace: ns, database: db)
        let first = try await client.signup(.accessRecord(access: "account", variables: [
            "email": .string("ada@example.com"), "pass": .string("secret"),
        ]))
        #expect(first.refresh != nil)

        // info() is the signed-in record.
        let me = try #require(try await client.info(as: AppUser.self))
        #expect(me.email == "ada@example.com")
        #expect(me.id.table == "user")

        // refresh() issues a new pair and burns the old refresh token.
        let second = try await client.refresh(first)
        #expect(second.access != first.access)
        #expect(second.refresh != nil && second.refresh != first.refresh)
        await #expect(throws: SurrealError.self) {
            _ = try await client.refresh(first)
        }

        // authenticate(tokens) refreshes once the access token has expired.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let third = try await client.authenticate(second)
        #expect(third.access != second.access)
        #expect(try await client.info(as: AppUser.self)?.email == "ada@example.com")

        // A failed refresh doesn't sign the client out.
        await #expect(throws: SurrealError.self) {
            _ = try await client.refresh(AuthTokens(access: third.access, refresh: "not-a-refresh-token"))
        }
        #expect(try await client.info(as: AppUser.self)?.email == "ada@example.com")

        // revoke() makes the refresh token useless, even once the access
        // token has expired (over HTTP it used to be rejected for that).
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await client.revoke(third)
        await #expect(throws: SurrealError.self) {
            _ = try await client.refresh(third)
        }
    }
}

@Test
func rpcError_causeMayBeNoneOrAString() {
    #expect(CBORSurrealCodec.decodeRPCCause(from: .none) == nil)
    #expect(CBORSurrealCodec.decodeRPCCause(from: .null) == nil)
    #expect(CBORSurrealCodec.decodeRPCCause(from: .string("why"))?.message == "why")
    #expect(CBORSurrealCodec.decodeRPCCause(from: .object(["message": .string("why")]))?.message == "why")
}

@Test
func integration_initialSessionContextIsAppliedOverWebSocket() async throws {
    guard IntegrationEnv.enabled else { return }

    let signedIn = try await integrationClient(wsEndpoint())
    guard case .string(let database)? = try await signedIn.queryRaw("RETURN session::db();").first?.result else {
        Issue.record("Expected a database name")
        return
    }
    _ = try await signedIn.queryRaw("CREATE thing:1 SET n = 1;")
    let token = try await signedIn.signin(.root(username: IntegrationEnv.user ?? "root", password: IntegrationEnv.password ?? "root"))
    await signedIn.close()

    // Namespace, database, token and variables given at init used to stay
    // local over WebSocket until a reconnect replayed them.
    let client = try SurrealClient(
        endpoint: wsEndpoint(),
        session: SessionContext(namespace: IntegrationEnv.namespace, database: database, accessToken: token.access, variables: ["v": .int(7)])
    )
    try await client.connect()
    defer { Task { await client.close() } }
    #expect(try await client.queryRaw("RETURN [$v, (SELECT VALUE n FROM ONLY thing:1)];").first?.result == .array([.int(7), .int(1)]))
}

/// Answers `version` with a fixed value and records whether it carried a
/// token.
private actor VersionEngine: RPCEngine {
    let answer: SurrealValue
    private(set) var versionTokens: [String?] = []

    init(answer: SurrealValue) { self.answer = answer }

    func connect() async throws {}
    func close() async {}
    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        if request.method == "version" {
            versionTokens.append(session.accessToken)
        }
        return RPCResponseEnvelope(id: request.id, action: nil, result: request.method == "version" ? answer : .null, error: nil)
    }
}

@Test
func version_acceptsStringAndObjectAndOmitsTheToken() async throws {
    for answer: SurrealValue in [
        .string("surrealdb-3.3.4"),
        .object(["version": .string("surrealdb-3.3.4"), "build": .string("abc"), "timestamp": .string("2026-01-01")]),
    ] {
        let engine = VersionEngine(answer: answer)
        let core = SurrealClientCore(engine: engine, sessionContext: SessionContext(accessToken: "stale"), checkServerVersion: true)
        try await core.connect()
        #expect(try await core.version() == "3.3.4")
        #expect(await engine.versionTokens == [nil, nil])
    }
    let core = SurrealClientCore(engine: VersionEngine(answer: .int(3)))
    await #expect(throws: SurrealError.self) { _ = try await core.version() }
}

@Test
func integration_httpConnectsDespiteAStaleToken() async throws {
    guard IntegrationEnv.enabled, IntegrationEnv.hasCredentials else { return }

    let client = try SurrealClient(endpoint: httpEndpoint(), session: SessionContext(accessToken: "stale.token.value"))
    try await client.connect()
    defer { Task { await client.close() } }
    try await authenticateIfNeeded(client)
    try await client.use(namespace: IntegrationEnv.namespace, database: IntegrationEnv.database)
    #expect(try await client.queryRaw("RETURN 1;").first?.result == .int(1))
}
