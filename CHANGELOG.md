# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed
- CI runs every integration test against a version matrix: SurrealDB 3.3.4 (pinned) and the nightly build. `scripts/test-integration.sh` takes the server binary from `SURREALDB_BIN`.
- The README's installation snippet now points at the current release.
- Over WebSocket, `set(_:value:)` and `unset(_:)` now define and remove the parameter on the server (`let`/`unset`), so SurrealQL the server evaluates on its own, such as functions and permission clauses, sees it. Variables are re-defined after a reconnect and copied into forked sessions. HTTP still sends them with each query.
### Added
- `SurrealWebSocketOptions.reconnectMaxDelay` caps the backoff between reconnect attempts.
- `version()` returns the server version, and `connect()` refuses servers outside 3.0.0 up to, but not including, 5.0.0 with `SurrealError.unsupportedServerVersion`. `SurrealClientOptions.checkServerVersion` turns the check off; the range is `ServerVersion.minimum`/`maximum`.
- `health()` checks the server's HTTP `/health` endpoint, over either transport.
- `info()` and `info(as:)` return the signed-in record user.
- `refresh(_:)` and `revoke(_:)` for record-access token pairs, and `authenticate(_: AuthTokens)`, which refreshes the pair when the access token has expired and returns the pair to keep. `AuthTokens.accessExpiry` reads the JWT's expiry, and `SurrealError.isTokenExpired` recognises an expired token over either transport.
- `reset()` clears the session's namespace, database, authentication and variables.
- Interactive transactions over WebSocket: `beginTransaction()` returns a `SurrealInteractiveTransaction` whose `query`, `queryRaw` and CRUD calls run inside a transaction held open on the server, until `commit()` or `cancel()`. `withTransaction { tx in ... }` commits on return and cancels on throw. Available on clients and sessions.
- `run(_:version:arguments:)` calls a server-side function by name, with a typed `run(_:version:arguments:as:)`.
- `api(_:method:body:headers:query:)` calls a `DEFINE API` endpoint through `api::invoke` and returns a `SurrealAPIResponse` (status, headers, body).
- `export(_:)` and `import(_:)` over the server's HTTP `/export` and `/import` routes, from either transport. `SurrealExportOptions` picks tables and definitions; a partly applied import throws the new `SurrealError.importFailed`.
- `insert(_:)` and `insertRelation(_:)` insert one or many records (or edges) in a single statement.
- `merge(recordID:with:as:)` and `merge(_:with:where:)` merge fields into records; `patch(recordID:_:as:)` applies JSON Patch operations (`SurrealPatchOperation`).
- `relate(_:_:_:content:as:)` creates edges, from one record to another or from each record in one list to each in another.
- Record ranges: `SurrealRecordRange` with `select(range:as:)`, `merge(range:with:as:)` and `delete(range:as:)`. `SurrealRange` can be built from Swift `Int64` ranges (`1...10`, `1..<10`, `5...`, `..<5`, `...5`).
- File references: `SurrealValue.file(SurrealFileRef)` for SurrealDB's file values (`f"bucket:/key"`, CBOR tag 55), which used to fail to decode. `SurrealFileRef` fields in Codable types map to it. The integration scripts start the server with the experimental `files` capability.
- Live queries survive a reconnect: the client re-issues each query it started with `live(_:)`, with its bindings, after replaying the session, and the same `AsyncStream` carries on under the new query id. Streams used to finish on any drop.
- `liveOf(_:as:)` attaches a stream to a live query that's already running, such as one started with a raw `LIVE SELECT`.
- `SurrealDSL.liveDiff(_:where:)` builds a `LIVE SELECT DIFF`, whose events decode to `[SurrealPatchOperation]`. `SurrealPatchOperation` is now `Decodable` and gains `.change(path:value:)` for SurrealDB's text diffs.

### Security
- Fixed SurrealQL injection in generated queries. Predicate values (`Person.Fields.name == x`) are now sent as bound variables instead of being spliced into the statement; table and field names are always backtick-escaped; record-id operations (`select(recordID:)`, `create(recordID:)` and the rest) send the id as a bound value; and `SurrealValue.sqlLiteral` now escapes backslashes, so a value ending in `\` can no longer close its own string. `SurrealPredicate` gains a `bindings` dictionary, and `SurrealPredicateValue` now requires `surrealPredicateValue: SurrealValue` in place of `surrealPredicateSQL` (source-breaking for custom conformances).
- Added `SurrealQL.escapeIdent(_:)`, `SurrealQL.escapeFieldPath(_:)` and `SurrealQL.quote(_:)` for callers writing their own SurrealQL.

### Fixed
- Live notifications that arrived before `live(_:)` had opened its stream were dropped. The WebSocket engine now holds notifications for live queries with no stream yet (up to 64 queries and 256 notifications each) and delivers them when one opens.
- An RPC error whose `cause` was NONE or a string failed to decode, and over WebSocket that closed the connection. Such errors now arrive as `SurrealError.serverError`.
- `update(_:content:)` and `upsert(_:content:)` with no predicate replaced every record in the table with the same content. The `where:` argument is now required (source-breaking); the table-wide forms are `updateAll(_:content:)` and `upsertAll(_:content:)`.
- An invalid UUID string (CBOR tag 9) silently decoded to a new random `UUID()`. It now throws `SurrealError.invalidResponse`, as do other malformed tags that used to decode to an invented value (`NULL`, `""`, `0`, an empty set). A malformed value inside a response no longer reads as a missing result.
- `KILLED` live notifications were dropped because they carry no record, so a live stream whose query the server ended (`KILL`, `REMOVE TABLE`, lost access) stayed open forever. The stream now delivers a `.killed` event and finishes. `LiveEvent` gains a typed `record: SurrealRecordID?`; `recordID` is `""` for `.killed`.
- WebSocket requests could hang forever: `requestTimeout` only applied to HTTP, and cancelling the calling task didn't stop the wait. Requests now throw `SurrealError.timeout` after `requestTimeout` and `CancellationError` as soon as the caller is cancelled, on both transports. The keepalive ping is bounded by the same timeout, so a peer that stops answering counts as a dropped connection.
- WebSocket reconnect limits never applied. `connect()` reported success for a dead host because it never waited for the handshake, so every reconnect "succeeded" and reset the attempt counter, and the receive and ping loops each started their own reconnect loop on a drop. `connect()` now waits for the server to answer an RPC `ping` (bounded by `requestTimeout`) and throws if it doesn't; a drop starts exactly one reconnect loop; and it stops after `maxReconnectAttempts`, with the delay doubling from `reconnectBaseDelay` up to the new `reconnectMaxDelay` (default 30 s).
- Typed decoding and encoding lost data by going through JSON: record ids became strings, `Date` and `UUID` were written as strings, datetimes lost their fractional seconds, and bytes became base64 text. `SurrealValue.decode(_:)` and `SurrealValue.fromEncodable(_:)` now convert directly, keeping `Date`, `UUID`, `Data`, `Decimal`, `SurrealRecordID` and `SurrealValue` fields as SurrealDB types. Record ids, UUIDs, durations and datetimes still decode into `String` fields as their text form. The JSON-based variants that take a `JSONDecoder`/`JSONEncoder` remain, deprecated.
- Datetimes before 1970 were clamped to the epoch when sent. They're now sent as floored seconds plus forward-counting nanoseconds, as the server does, and malformed datetime tags throw instead of decoding to `NULL`.
- Durations decoded as `""`. The server sends tag 14 as `[seconds, nanoseconds]`, and the SDK only read a string; it now decodes that form into the server's canonical text (`1h30m`), and sends `.duration` values in the same form. Malformed duration tags now throw instead of decoding to an empty string. New `SurrealValue.duration(seconds:nanoseconds:)` and `durationComponents` convert between the two.

## [1.0.0]
### Changed
- Renamed the Spectron client to Agent Memory: the library product and module `Spectron` is now `AgentMemory`, and the types it exports lose the `Spectron` prefix (`Spectron` → `AgentMemory`, `SpectronError` → `AgentMemoryError`, `SpectronTransport` → `AgentMemoryTransport`, and so on). Source-breaking for anyone on `v1.0.0-alpha.1`.

### Added
- Initial SurrealDB Swift client: core query builder, table/field modeller, transport protocol abstraction (HTTP/WebSocket), CBOR codec, and integration test harness.
- Engine and codec abstraction, plus the Agent Memory SDK.
- Typed `ServerErrorKind` enum taxonomy mirroring the server's `{code, message, kind, details, cause}` wire shape, with convenience booleans (`isTokenExpired`, `isInvalidAuth`, `isTransactionConflict`, `isNotFound`, `isAlreadyExists`, etc.) (#5).
- Multi-session support: one WebSocket connection can now multiplex multiple independent sessions (namespace/database/auth/bound variables), via `newSession()`/`forkSession()`/`closeSession()`/`sessions()`, mirroring `surrealdb.js`'s multi-session model. WebSocket only — HTTP throws `SurrealError.unsupportedFeature` (#6).
- `set()`/`unset()` on `SurrealQueryable` for client-side session-scoped bound variables (#6).
- Reconnect-replay mechanism restoring a session's namespace/database/auth after a WebSocket reconnect, fixing a pre-existing bug where that state was silently dropped (#6).

### Fixed
- `QueryErrorDetail` was silently dropping `kind` for per-statement query failures; it now carries `kind` and exposes `.typedKind` (#5).
- JSON wire codec was silently dropping the `session`/`txn` fields the CBOR codec already carried (#6).

[Unreleased]: https://github.com/surrealdb/surrealdb.swift/compare/v1.0.0...HEAD
