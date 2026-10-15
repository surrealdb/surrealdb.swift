# SurrealDB Swift SDK

A Swift SDK for [SurrealDB](https://surrealdb.com) with full async/await support, type-safe query macros, and live query streaming.

> **Alpha release** - this SDK is in early development and the public API is subject to breaking changes without notice.

## Requirements

- Swift 6.1+
- SurrealDB 3.x (CI tests 3.3.4 and the nightly build)

## Platforms

iOS 17+ · macOS 14+ · tvOS 17+ · watchOS 10+ · visionOS 1+

## Features

- Pluggable transport engines (HTTP, WebSocket) with room for additional engines (e.g. embedded) down the line
- Pluggable wire protocols (CBOR, JSON) — opt into either per-client
- Type-safe CRUD via `@SurrealModel` macro and query DSL
- Live queries over WebSocket via `AsyncStream`
- Multi-session: fork independent namespace/database/auth/variable contexts over one WebSocket connection
- Client-side transactions with automatic binding-collision rewriting
- Raw SQL queries with bound parameters
- Root, namespace, database, and record-access authentication
- Automatic WebSocket reconnection

---

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/surrealdb/surrealdb.swift.git", from: "1.0.0-alpha.2"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SurrealDB", package: "surrealdb.swift")
        ]
    )
]
```

---

## Quick Start

```swift
import SurrealDB

// 1. Define a model
@SurrealModel("person")
struct Person: Codable, Sendable {
    let id: String?
    let name: String
    let age: Int
}

// 2. Create a client and connect (the engine is chosen from the URL scheme)
let client = try SurrealClient(endpoint: "ws://localhost:8000")
try await client.connect()

// 3. Authenticate and select a namespace/database
_ = try await client.signin(.root(username: "root", password: "root"))
try await client.use(namespace: "myapp", database: "mydb")

// 4. Create a record
let people = try await client.create(Person(id: nil, name: "Ada", age: 30))

// 5. Query records
let results = try await client.select(Person.self, where: Person.Fields.age > 18, limit: 10)
```

---

## Defining Models

Annotate any `struct`, `class`, or `actor` with `@SurrealModel` to bind it to a SurrealDB table. The macro generates a `surrealTable` constant, a `SurrealModel` conformance, and a `Fields` namespace for type-safe predicates.

```swift
@SurrealModel("article")
struct Article: Codable, Sendable {
    let id: String?
    let title: String
    let published: Bool
    let views: Int
}

// Generated Fields:
// Article.Fields.id      → SurrealField<Article, String?>
// Article.Fields.title   → SurrealField<Article, String>
// Article.Fields.published → SurrealField<Article, Bool>
// Article.Fields.views   → SurrealField<Article, Int>
```

If you prefer not to use the macro, conform to `SurrealModel` manually:

```swift
struct Article: SurrealModel, Codable, Sendable {
    static let surrealTable = "article"
    let id: String?
    let title: String
}
```

---

## Connecting

A single `SurrealClient` serves both transports. The engine is selected from the endpoint scheme: `ws://` and `wss://` use the WebSocket engine (live queries, automatic reconnection), while `http://` and `https://` use the request/response HTTP engine.

```swift
// WebSocket engine, inferred from the scheme
let ws = try SurrealClient(endpoint: "ws://localhost:8000")
try await ws.connect()
defer { Task { await ws.close() } }

// HTTP engine, inferred from the scheme
let http = try SurrealClient(endpoint: "http://localhost:8000")
try await http.connect()
defer { Task { await http.close() } }
```

The selected engine is exposed on the client:

```swift
let client = try SurrealClient(endpoint: "wss://example.com")
client.engine  // .webSocket
```

Live queries are only available over WebSocket. Calling `live(_:)` on a client created with an HTTP endpoint throws `SurrealError.unsupportedFeature`.

WebSocket reconnection is configurable via `websocketOptions`, which is ignored for HTTP endpoints:

```swift
let client = try SurrealClient(
    endpoint: "ws://localhost:8000",
    websocketOptions: SurrealWebSocketOptions(
        reconnectEnabled: true,
        maxReconnectAttempts: 8,
        reconnectBaseDelay: 0.5,
        reconnectMaxDelay: 30
    )
)
```

`connect()` waits for the server to answer before returning, and throws if it can't be reached within `requestTimeout`. After a drop, the client retries up to `maxReconnectAttempts` times, doubling the delay from `reconnectBaseDelay` up to `reconnectMaxDelay`, then gives up; calling `connect()` again starts over.

### Wire Protocol

The client defaults to SurrealDB's tagged CBOR encoding, which preserves all `SurrealValue` types (UUID, datetime, decimal, duration, record IDs, geometries, ranges, and so on) losslessly. JSON is also supported and may be preferable for environments where CBOR is harder to inspect.

```swift
// CBOR (default), full fidelity
let cbor = try SurrealClient(endpoint: "ws://localhost:8000")

// JSON, primitives only; SurrealDB-specific types are coerced to strings
let json = try SurrealClient(
    endpoint: "http://localhost:8000",
    wireProtocol: .json
)
```

The wire protocol controls both the HTTP `Content-Type` and the WebSocket sub-protocol negotiated during the handshake.

### Selecting a Namespace and Database

```swift
try await client.use(namespace: "myapp", database: "mydb")
```

---

## Authentication

### Root

```swift
let tokens = try await client.signin(.root(username: "root", password: "root"))
```

### Namespace user

```swift
let tokens = try await client.signin(.namespace(
    namespace: "myapp",
    username: "ns_user",
    password: "secret"
))
```

### Database user

```swift
let tokens = try await client.signin(.database(
    namespace: "myapp",
    database: "mydb",
    username: "db_user",
    password: "secret"
))
```

### Record access (custom variables)

```swift
let tokens = try await client.signin(.accessVariables(
    namespace: "myapp",
    database: "mydb",
    access: "account",
    variables: ["email": .string("user@example.com"), "pass": .string("secret")]
))
```

### Bearer token access

```swift
let tokens = try await client.signin(.accessBearer(
    namespace: "myapp",
    database: "mydb",
    access: "account",
    key: "bearer-token-value"
))
```

### Sign up (record access)

```swift
let tokens = try await client.signup(.accessRecord(
    namespace: "myapp",
    database: "mydb",
    access: "account",
    variables: ["email": .string("new@example.com"), "pass": .string("secret")]
))
```

### Resuming a session

```swift
try await client.authenticate(tokens.access)

// Or start with a pre-existing token
let client = try SurrealClient(
    endpoint: "http://localhost:8000",
    session: SessionContext(
        namespace: "myapp",
        database: "mydb",
        accessToken: "existing-jwt"
    )
)
```

With a token pair from a record access method that has `WITH REFRESH`, `authenticate` refreshes the pair if the access token has expired, and returns the pair to keep:

```swift
tokens = try await client.authenticate(tokens)

// Or explicitly
tokens = try await client.refresh(tokens)

// Make the refresh token unusable, for example on sign-out
try await client.revoke(tokens)
```

`info()` returns the signed-in record user, and `info(as:)` decodes it:

```swift
let me = try await client.info(as: User.self)
```

`SessionContext` here is a static, local snapshot passed at `init` to resume a login — it has no identity on the server. Don't confuse it with `SurrealSession` (below), a live, forkable, server-tracked session identified by a `SessionID`.

### Invalidating a session

```swift
try await client.invalidate()
```

### Server information

```swift
let version = try await client.version()  // "3.3.4"
try await client.health()                 // throws if the server isn't healthy
```

`health()` calls the server's HTTP `/health` endpoint, whichever transport the client uses.

`connect()` checks the server version and throws `SurrealError.unsupportedServerVersion` for anything outside `ServerVersion.minimum` (3.0.0) up to, but not including, `ServerVersion.maximum` (5.0.0). Set `checkServerVersion: false` in `SurrealClientOptions` to skip the check.

---

## Sessions

A `SurrealClient` is always scoped to its connection's default session (`client.id == nil`). On a WebSocket endpoint, you can multiplex additional, fully independent sessions — each with its own namespace, database, authentication, and bound variables — over that same connection via `SurrealSession`. This is unavailable over HTTP: `newSession()`/`forkSession()`/`sessions()` throw `SurrealError.unsupportedFeature` on HTTP clients, since there's no persistent connection for the server to attach a session to.

### Creating a session

```swift
// Blank — nothing inherited from the client's default session
let session = try await client.newSession()
try await session.use(namespace: "myapp", database: "mydb")
try await session.signin(.root(username: "root", password: "root"))
```

### Forking a session

```swift
// Clones the source session's namespace, database, authentication, and
// variables into a brand new, independent session
let forked = try await session.forkSession()
```

### Binding variables

```swift
try await session.set("minAge", value: .int(18))
let adults = try await session.queryRaw("SELECT * FROM person WHERE age >= $minAge;")
try await session.unset("minAge")
```

`set`/`unset` are also available on `SurrealClient` itself, scoped to the default session.

Over WebSocket, `set` and `unset` define and remove the parameter on the server (the `let` and `unset` RPC methods), so anything the server evaluates for that session sees it, and they're defined again after a reconnect. HTTP keeps no session state on the server, so there the variables are sent with each query instead.

`reset()` clears the session: namespace, database, authentication and variables.

### Closing a session

```swift
try await session.closeSession()
let isValid = await session.isValid // false

// Or, to always close even if the closure throws:
let result = try await client.newSession().withSession { session in
    try await session.use(namespace: "myapp", database: "mydb")
    return try await session.queryRaw("RETURN 1;")
}
```

### Listing and re-attaching sessions

```swift
let ids = try await client.sessions()          // session ids attached to this connection
let handle = client.session(id: ids[0])         // re-attach a handle without re-validating it
```

Session state is tracked per client instance: `session(id:)` only works for ids this client created (sessions are scoped to their connection, so an id from another client can't exist here anyway). A handle around a closed or foreign id throws `SurrealError.invalidSession` on use, and its `isValid` reports `false`.

### Reconnection behaviour

When the WebSocket reconnects after a drop, the client automatically re-attaches every session and replays its namespace/database selection and authentication. Bound variables live client-side, so they survive reconnects without any replay. Live queries are **not** re-registered — their streams finish when the connection drops and must be re-opened by the caller.

`SurrealSession` conforms to the same `SurrealQueryable`/`SurrealLiveQueryable` protocols as `SurrealClient`, so every query, CRUD, and live-query method shown elsewhere in this README works identically on a session.

---

## CRUD Operations

### Select (all records)

```swift
// All records
let people = try await client.select(Person.self)

// With a predicate, limit, and offset
let adults = try await client.select(
    Person.self,
    where: Person.Fields.age >= 18,
    limit: 20,
    start: 0
)
```

### Select (single record by ID)

```swift
let id = SurrealRecordID(table: "person", id: .string("ada"))
let person: Person? = try await client.select(recordID: id, as: Person.self)
```

### Create

```swift
// Auto-generated ID
let created: [Person] = try await client.create(Person(id: nil, name: "Ada", age: 30))

// Specific record ID
let id = SurrealRecordID(table: "person", id: .string("ada"))
let record: Person? = try await client.create(
    recordID: id,
    content: Person(id: nil, name: "Ada", age: 30)
)
```

### Update

```swift
// Update all matching records
let updated = try await client.update(
    Person.self,
    content: Person(id: nil, name: "Ada", age: 31),
    where: Person.Fields.name == "Ada"
)

// The predicate is required. To replace every record in the table, say so:
let all = try await client.updateAll(Person.self, content: Person(id: nil, name: "Ada", age: 31))

// Update a specific record
let id = SurrealRecordID(table: "person", id: .string("ada"))
let record: Person? = try await client.update(
    recordID: id,
    content: Person(id: nil, name: "Ada", age: 31)
)
```

### Upsert

```swift
let upserted = try await client.upsert(
    Person.self,
    content: Person(id: nil, name: "Ada", age: 31),
    where: Person.Fields.name == "Ada"
)
```

### Delete

```swift
// Delete matching records
let deleted = try await client.delete(Person.self, where: Person.Fields.age < 18)

// Delete a specific record
let id = SurrealRecordID(table: "person", id: .string("ada"))
let record: Person? = try await client.delete(recordID: id, as: Person.self)
```

---

## Predicates

`Fields` properties support Swift comparison operators that produce type-safe `SurrealPredicate` values.

```swift
// Equality
Person.Fields.name == "Ada"
Person.Fields.name != "Bob"

// Comparisons
Person.Fields.age > 18
Person.Fields.age >= 21
Person.Fields.age < 65
Person.Fields.age <= 60

// Combining
let predicate = Person.Fields.age >= 18 && Person.Fields.published == true
let either    = Person.Fields.age < 18  || Person.Fields.name == "Admin"
let negated   = !(Person.Fields.published == false)

// Raw string predicate
let raw = SurrealPredicate(raw: "age > 18 AND name != 'Bot'")
```

---

## Query Macros

The SDK ships expression macros that resolve to `SurrealDSL` calls at compile time. Use them anywhere you would build a `SurrealQuery` by hand.

```swift
import SurrealDB

let selectQuery  = #select(Person.self, where: Person.Fields.age > 18, limit: 10)
let createQuery  = #create(Person.self)
let updateQuery  = #update(Person.self, where: Person.Fields.name == "Ada")
let upsertQuery  = #upsert(Person.self)
let deleteQuery  = #delete(Person.self, where: Person.Fields.age < 18)
let liveQuery    = #live(Person.self)

let people = try await client.query(selectQuery)
```

---

## Type-Safe Query DSL

`SurrealDSL` is the programmatic alternative to the macros, useful when you need to build queries at runtime.

```swift
let query = SurrealDSL.select(
    Person.self,
    where: Person.Fields.age >= 21,
    limit: 50,
    start: 0
)
let people = try await client.query(query)

let createQuery = SurrealDSL.create(
    Person.self,
    contentBinding: "content",
    bindings: ["content": try .fromEncodable(newPerson)]
)
let created = try await client.query(createQuery)
```

---

## Live Queries

Live queries require a WebSocket endpoint (`ws://` or `wss://`) and return an `AsyncStream<LiveEvent<T>>`. On an HTTP endpoint, `live(_:)` throws `SurrealError.unsupportedFeature`.

```swift
let client = try SurrealClient(endpoint: "ws://localhost:8000")
try await client.connect()
_ = try await client.signin(.root(username: "root", password: "root"))
try await client.use(namespace: "myapp", database: "mydb")

let stream = try await client.live(SurrealDSL.live(Person.self))

for await event in stream {
    switch event.action {
    case .create:
        print("Created:", event.decoded as Any)
    case .update:
        print("Updated:", event.decoded as Any)
    case .delete:
        print("Deleted record:", event.recordID)
    case .killed:
        print("Live query was killed")
    }
}
```

Cancel the stream by killing the live query:

```swift
// Capture the queryID from the first event, then:
try await client.kill(liveQueryID: event.queryID)
```

---

## Raw Queries

Run arbitrary SurrealQL with bound parameters:

```swift
let results: [RPCQueryResult] = try await client.queryRaw(
    "SELECT * FROM person WHERE age > $minAge LIMIT $limit;",
    bindings: [
        "minAge": .int(18),
        "limit":  .int(50)
    ]
)

for row in results {
    if row.status == .ok {
        print(row.result) // SurrealValue
    }
}
```

---

## Transactions

`transaction { tx in … }` bundles multiple statements into a single `BEGIN; … COMMIT;` query call. SurrealDB cancels the transaction server-side if any statement fails.

```swift
let results = try await client.transaction { tx in
    tx.append(
        "CREATE person CONTENT $content",
        bindings: ["content": try .fromEncodable(Person(id: nil, name: "Ada", age: 30))]
    )
    tx.append(
        "UPDATE person SET age = 31 WHERE name = $name",
        bindings: ["name": .string("Ada")]
    )
}
```

Typed `SurrealQuery<T>` values (including those produced by the macros and DSL) can be appended directly:

```swift
try await client.transaction { tx in
    tx.append(#create(Person.self))
    tx.append(#update(Person.self, where: Person.Fields.name == "Ada"))
}
```

If two statements share a binding name with different values, the second one is automatically renamed (`$content` → `$content_tx1`) and its SQL is rewritten to match — so you can freely combine independently built queries.

To abort before flushing, simply throw from the closure; no `BEGIN` is sent.

```swift
try await client.transaction { tx in
    tx.append(#create(Person.self))
    if shouldAbort { throw MyError.cancelled } // nothing is sent to the server
    tx.append(#update(Person.self))
}
```

---

## SurrealValue

`SurrealValue` is the SDK's universal value type for working with raw SurrealDB data.

```swift
// Constructing values
let v: SurrealValue = .string("hello")
let v: SurrealValue = .int(42)
let v: SurrealValue = .double(3.14)
let v: SurrealValue = .bool(true)
let v: SurrealValue = .null
let v: SurrealValue = .array([.string("a"), .int(1)])
let v: SurrealValue = .object(["name": .string("Ada"), "age": .int(30)])
let v: SurrealValue = .uuid(UUID())
let v: SurrealValue = .datetime(Date())
let v: SurrealValue = .recordID(SurrealRecordID(table: "person", id: .string("ada")))

// Convert any Encodable to SurrealValue
let value = try SurrealValue.fromEncodable(myStruct)

// Decode a SurrealValue back to a Swift type
let person = try value.decode(Person.self)
```

---

## Configuration

### `SurrealClientOptions`

Applies to both HTTP and WebSocket clients:

```swift
SurrealClientOptions(
    requestTimeout: 20,        // seconds, default 20
    pingInterval: 30,          // seconds, default 30
    checkServerVersion: true   // default true
)
```

### `SurrealWebSocketOptions`

```swift
SurrealWebSocketOptions(
    reconnectEnabled: true,       // default true
    maxReconnectAttempts: 8,      // default 8
    reconnectBaseDelay: 0.5,      // seconds, default 0.5
    reconnectMaxDelay: 30         // seconds, default 30
)
```

### `SessionContext`

Pre-populate namespace, database, and access token at init time:

```swift
SessionContext(
    namespace: "myapp",
    database: "mydb",
    accessToken: nil,
    variables: [:]
)
```

---

## Agent Memory

The package also ships an `AgentMemory` library product, a client for [Agent Memory](https://surrealdb.com/agent-memory), SurrealDB's memory and knowledge API. Add it to your target alongside `SurrealDB` (or on its own):

```swift
.product(name: "AgentMemory", package: "surrealdb.swift")
```

```swift
import AgentMemory

let memory = try AgentMemory(
    context: "acme-prod",
    endpoint: "https://api.memory.example",
    apiKey: "sk-spec-..."
)

// Record a memory, then recall it
_ = try await memory.remember("Tobie was promoted to CTO", role: .user)
let hits = try await memory.recall("what is Tobie's role?", k: 5)
```

The client is `Sendable` and built on Swift `async/await`. The underlying `AgentMemoryTransport` is an actor backed by `URLSession`, and you can swap in your own `HTTPClient` for testing.

The surface is grouped into `documents` (Layer 0 knowledge), `memory` (retrieval, sessions, entities, facts, lifecycle, traces), and governance (`scopes`, `principals`, `keys`). The most common operations are also exposed directly on the client as `remember`, `recall`, `rememberMany`, `forget`, and `chat`.

Every method accepts an optional `onBehalfOf:` argument that performs the request as another principal (sent as the `X-Spectron-On-Behalf-Of` header), subject to your key's delegation grants. Writes to `remember` / `rememberMany` carry an `Idempotency-Key` derived from the request, so a retried write is deduplicated server-side rather than applied twice.

### Documents

Documents are uploaded as multipart form data. Optional metadata (`title`, `source`) is sent as a JSON part ahead of the file; the file's MIME type is inferred from the `AgentMemoryFile` you supply.

```swift
let doc = try await memory.documents.upload(
    file: .fileURL(URL(fileURLWithPath: "returns.pdf"), filename: nil, mimeType: "application/pdf"),
    title: "Returns Policy",
    source: "https://example.com/returns"
)

_ = try await memory.documents.get(doc.id)
_ = try await memory.documents.replace(documentId: doc.id, file: .fileURL(URL(fileURLWithPath: "returns_v2.pdf"), filename: nil, mimeType: "application/pdf"))
_ = try await memory.documents.raw(doc.id)
_ = try await memory.documents.chunks(doc.id, page: 0, pageSize: 50)
_ = try await memory.documents.keywordsFor(doc.id)
_ = try await memory.documents.list(status: .ready, mimeType: "application/pdf")
_ = try await memory.documents.recomputeLinks()
try await memory.documents.delete(doc.id)
```

Query:

```swift
let hits = try await memory.documents.query(
    "what is the return window for unopened items?",
    mode: .hybridGraph,
    k: 10,
    threshold: 0.5,
    vectorWeight: 0.5,
    rrfK: 60,
    graphAlpha: 0.3,
    graphEdges: [.knowledgeHasKeyword, .documentLink],
    graphDepth: 2,
    expandGraph: true,
    useReranker: true,
    filter: QueryFilter(documentIds: nil, mimeType: ["application/pdf"])
)
```

Keywords:

```swift
_ = try await memory.documents.keywords.list(minDocumentCount: 2, sort: "-document_count", q: "return")
_ = try await memory.documents.keywords.search("refund policies", k: 10, threshold: 0.6)
_ = try await memory.documents.keywords.get("return policy")
```

### Sessions and facts

Facts are the ingestion path for memory. A fact can be free text (the server extracts entities, attributes, and relations) or a set of explicit triples.

```swift
let session = try await memory.sessions.create(scope: ["user/tobie"])

_ = try await session.ingest(text: "I just got promoted to CTO", role: .user)

let ctx = try await session.context("What is Tobie's role?")
let reply = try await myLLM.chat(system: ctx.context, user: userMessage)
_ = try await session.ingest(text: reply, role: .assistant)

_ = try await session.turns()
try await session.close()
```

Ingest without a session, or in bulk, directly on the client. `remember` and `rememberMany` are the top-level verbs; the equivalent `memory.facts.create` / `memory.facts.batch` namespace methods are also available.

```swift
_ = try await memory.remember(
    triples: [
        Triple(
            entity: TripleEntity(type: "Person", name: "tobie"),
            key: "role",
            value: "CTO",
            memoryCategory: .identity
        )
    ],
    infer: .triples
)

_ = try await memory.rememberMany(
    [
        BatchMessage(role: .user, content: "I work at SurrealDB"),
        BatchMessage(role: .assistant, content: "Noted.")
    ],
    extract: .wholeConversation
)
```

Or let AgentMemory run the managed chat loop, which retrieves context, replies, and persists the exchange in one call:

```swift
let reply = try await session.chat("What do you know about me?")
// or, scoped to a session id on the client:
let reply = try await memory.chat("What do you know about me?", sessionId: session.id)
```

Chat can also stream incrementally over Server-Sent Events:

```swift
for try await chunk in try await memory.chatStream("Summarise what you know about me") {
    if chunk.done {
        print("\n[trace: \(chunk.traceId ?? "")]")
    } else {
        print(chunk.delta, terminator: "")
    }
}
```

### Retrieval, state, profile, entities

```swift
_ = try await memory.query("What role does Christian have?", k: 10)
_ = try await memory.context("brief on tobie", k: 10)

_ = try await memory.state()
_ = try await memory.profile()

_ = try await memory.entities.list(type: "Person")
_ = try await memory.entities.get(type: "Person", name: "christian_battaglia")
_ = try await memory.entities.history(type: "Person", name: "christian_battaglia", key: "role")
try await memory.entities.delete(type: "Person", name: "christian_battaglia")
```

`entities.delete` is a soft delete.

### Reflect, forget, lifecycle, maintenance, traces

```swift
_ = try await memory.reflect("patterns in customer complaints this month?", persist: true)
_ = try await memory.forget("anything about my old job")          // purge: false by default

_ = try await memory.lifecycle.expire()                            // -> affected count
_ = try await memory.lifecycle.decay()

_ = try await memory.consolidate(dryRun: true)                     // promote observations into facts
_ = try await memory.elaborate(sweep: true, dryRun: true)          // infer new relations
_ = try await memory.fsck()                                        // integrity report

_ = try await memory.inspect(ref: "Person/tobie")                  // entity, attribute, relation, or trace
_ = try await memory.audit(limit: 100)

_ = try await memory.traces.list(limit: 50)
_ = try await memory.traces.get("trace:abc123")
_ = try await memory.traces.stats()
```

### Scopes, principals, and keys

Governance lives under `scopes`, `principals`, and `keys`.

```swift
_ = try await memory.scopes.list()
_ = try await memory.scopes.register(path: "org/anneal", displayName: "Anneal")
_ = try await memory.scopes.forget(path: "org/anneal")
try await memory.scopes.delete(path: "org/anneal")

_ = try await memory.principals.list()
_ = try await memory.principals.get("agent:reader")
_ = try await memory.principals.effective(principalId: "agent:reader", path: "org/anneal")
_ = try await memory.principals.grant(principalId: "agent:reader", path: "org/anneal", verbs: ["read"])
_ = try await memory.principals.revoke(principalId: "agent:reader", path: "org/anneal", verbs: ["read"])
```

Self-service API keys. The minted secret is returned only once, at creation or rotation:

```swift
let minted = try await memory.keys.create(name: "ci", grants: ["org/anneal": ["read"]], ttlSeconds: 3600)
// minted.key is the full bearer secret, shown only here

_ = try await memory.keys.list()
_ = try await memory.keys.rotate(minted.id, ttlSeconds: 3600)
try await memory.keys.delete(minted.id)
```

### Delegation and identity

Pass `onBehalfOf:` to any method to act as another principal, and use `whoami` to resolve the identity the server sees:

```swift
let docs = try await memory.documents.list(onBehalfOf: "agent:reader")
let me = try await memory.whoami(onBehalfOf: "agent:reader")
print(me.principalId, me.delegatedPrincipalId ?? "")
```

### Health

```swift
_ = try await memory.health()
```

### Errors

All failures throw `AgentMemoryError`, a single struct carrying `status`, `title`, `detail`, and `retryAfter` (plus `typeURI`, `instance`, and `extensions` for forward compatibility). The end-user API returns errors as `{ "message": "..." }`, which is surfaced as `title`. The `kind` field maps the HTTP status to one of `.base`, `.auth`, `.scope`, `.notFound`, `.validation`, `.rateLimit`, or `.server`.

```swift
do {
    _ = try await memory.documents.get("doc:missing")
} catch let error as AgentMemoryError where error.isNotFound {
    print(error.status, error.title)
} catch let error as AgentMemoryError where error.isRateLimit {
    print("retry after", error.retryAfter ?? 0, "seconds")
}
```

| Status | `kind` |
|---|---|
| 400, 422 | `.validation` |
| 401 | `.auth` |
| 403 | `.scope` |
| 404 | `.notFound` |
| 429 | `.rateLimit` (with `retryAfter`) |
| 5xx | `.server` |

### Retries, timeouts, scope

`GET` requests retry on connection errors and 5xx responses with backoff 250ms, 500ms, 1s (up to `maxRetries`, default 3). Writes are not retried, except `remember` / `rememberMany`, which carry an `Idempotency-Key` and so are retried safely. Default request timeout is 30 seconds, overridable on the `AgentMemory` initialiser.

Scope identifies the memory region a write targets. On requests that accept it (`remember`, `rememberMany`, `chat`, `sessions.create`, `documents.upload`), the `scope:` argument is a `Scope` value in disjunctive normal form: an OR of AND-clauses. A bare string is a single-path clause, a flat list is an OR of clauses, and a nested array is a single AND-clause, so the forms mix freely. All forms normalise to an ordered, de-duplicated list of clauses with empty paths and empty clauses dropped; omitting it uses the key's default write region. Note that a flat list of two or more paths means OR, not AND. To require several paths together, nest them in one clause.

```swift
_ = try await memory.remember("...", scope: "team/eng")                     // [["team/eng"]]
_ = try await memory.remember("...", scope: ["team/eng", "org/acme"])       // team/eng OR org/acme
_ = try await memory.remember("...", scope: [["team/eng", "org/acme"]])     // team/eng AND org/acme
_ = try await memory.remember("...", scope: ["team/eng", ["org/acme", "tier/gold"]])
//                                                          team/eng OR (org/acme AND tier/gold)
_ = try await memory.remember("...", scope: Scope(runtimeClauses))          // from a [[String]] value
```

Reads narrow with the same type: pass `lens:` to `recall` (and `memory.query` / `memory.context`) to restrict results to one or more scope clauses. Sessions return their scope the same way, as a list of clauses.

### Custom transport for testing

`AgentMemoryTransport` accepts any `HTTPClient`, so unit tests can replay canned responses without hitting the network:

```swift
let mock = MyMockHTTPClient()
mock.enqueue(.json(["ok": true]))
let transport = try AgentMemoryTransport(endpoint: "https://example", apiKey: "k", client: mock, sleeper: { _ in })
let client = AgentMemory(context: "ctx", transport: transport)
```

---

## Tests

Run unit tests:

```sh
swift test
```

Run integration tests (requires a running SurrealDB instance):

```sh
SURREALDB_RUN_INTEGRATION=1 swift test
```

Integration environment variables:

| Variable | Default | Notes |
|---|---|---|
| `SURREALDB_HOST` | `127.0.0.1:8000` | `host[:port]` or a full URL with scheme. WS/HTTP endpoints are derived. |
| `SURREALDB_NAMESPACE` | `test` | Passed to `client.use(namespace:database:)`. |
| `SURREALDB_NAME` | `test` | Database name. |
| `SURREALDB_USER` | _(unset)_ | If unset, sign-in is skipped. |
| `SURREALDB_PASSWORD` | _(unset)_ | If unset, sign-in is skipped. |
| `SURREALDB_AUTH_LEVEL` | `root` | One of `root`, `namespace` / `ns`, `database` / `db`. |

`./scripts/test-integration.sh` starts a server and runs every `integration_` test against it. Set `SURREALDB_BIN` to choose the `surreal` binary, or `SURREALDB_IMAGE_TAG` for the Docker image. CI runs the suite against SurrealDB 3.3.4 and the nightly build.

---

## License

Apache 2.0 - see [LICENSE](LICENSE).
