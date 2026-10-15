import Foundation
import Testing
@testable import SurrealDB

private struct Account: SurrealModel, Codable, Sendable {
    static let surrealTable = "account"
    var id: SurrealRecordID?
    var name: String
    var balance: Int

    init(id: SurrealRecordID? = nil, name: String, balance: Int) {
        self.id = id
        self.name = name
        self.balance = balance
    }

    enum Fields {
        static let name = SurrealField<Account, String>("name")
    }
}

private struct Abort: Error {}

/// Another server-side session on the same database as `client`.
private func siblingSession(of client: SurrealClient) async throws -> SurrealSession {
    guard case .string(let database)? = try await client.queryRaw("RETURN session::db();").first?.result else {
        throw Abort()
    }
    let session = try await client.newSession()
    try await authenticateIfNeeded(session)
    try await session.use(namespace: IntegrationEnv.namespace, database: database)
    return session
}

@Test
func interactiveTransaction_unsupportedOverHTTP() async throws {
    let client = try SurrealClient(endpoint: "http://127.0.0.1:1")
    await #expect(throws: SurrealError.self) {
        _ = try await client.beginTransaction()
    }
}

@Test
func integration_interactiveTransactionCommitAndCancel() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }
    // A second server-side session on the same database, outside the
    // transaction.
    let other = try await siblingSession(of: client)
    _ = try await client.queryRaw("DEFINE TABLE account SCHEMALESS;")

    let tx = try await client.beginTransaction()
    _ = try await tx.create(recordID: SurrealRecordID(table: "account", id: .string("ada")), content: Account(name: "ada", balance: 10))
    _ = try await tx.queryRaw("UPDATE account:ada SET balance += $n;", bindings: ["n": .int(5)])

    // Visible inside the transaction, not outside it.
    let inside = try await tx.select(recordID: SurrealRecordID(table: "account", id: .string("ada")), as: Account.self)
    #expect(inside?.balance == 15)
    #expect(try await other.select(Account.self).isEmpty)
    #expect(try await client.select(Account.self).isEmpty)

    try await tx.commit()
    #expect(try await other.select(Account.self).map { $0.balance } == [15])

    // A cancelled transaction leaves nothing behind.
    let cancelled = try await client.beginTransaction()
    _ = try await cancelled.create(Account(name: "bob", balance: 1))
    _ = try await cancelled.update(Account.self, content: Account(name: "ada", balance: 0), where: Account.Fields.name == "ada")
    try await cancelled.cancel()
    #expect(try await client.select(Account.self).map { $0.balance } == [15])

    // The id is gone after commit or cancel.
    await #expect(throws: SurrealError.self) {
        _ = try await cancelled.queryRaw("RETURN 1;")
    }
    await #expect(throws: SurrealError.self) {
        try await tx.commit()
    }
}

@Test
func integration_withTransactionCommitsOrCancels() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(wsEndpoint())
    defer { Task { await client.close() } }

    let created = try await client.withTransaction { tx in
        try await tx.create(Account(name: "ada", balance: 1)).count
    }
    #expect(created == 1)

    await #expect(throws: Abort.self) {
        try await client.withTransaction { tx in
            _ = try await tx.create(Account(name: "bob", balance: 2))
            throw Abort()
        }
    }
    #expect(try await client.select(Account.self).map { $0.name } == ["ada"])

    // Sessions have their own transactions.
    let session = try await siblingSession(of: client)
    try await session.withTransaction { tx in
        _ = try await tx.create(Account(name: "cy", balance: 3))
        #expect(try await client.select(Account.self).count == 1)
    }
    #expect(try await client.select(Account.self).count == 2)
}
