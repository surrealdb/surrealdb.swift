# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Security
- Fixed SurrealQL injection in generated queries. Predicate values (`Person.Fields.name == x`) are now sent as bound variables instead of being spliced into the statement; table and field names are always backtick-escaped; record-id operations (`select(recordID:)`, `create(recordID:)` and the rest) send the id as a bound value; and `SurrealValue.sqlLiteral` now escapes backslashes, so a value ending in `\` can no longer close its own string. `SurrealPredicate` gains a `bindings` dictionary, and `SurrealPredicateValue` now requires `surrealPredicateValue: SurrealValue` in place of `surrealPredicateSQL` (source-breaking for custom conformances).
- Added `SurrealQL.escapeIdent(_:)`, `SurrealQL.escapeFieldPath(_:)` and `SurrealQL.quote(_:)` for callers writing their own SurrealQL.

### Fixed
- Typed decoding and encoding lost data by going through JSON: record ids became strings, `Date` and `UUID` were written as strings, datetimes lost their fractional seconds, and bytes became base64 text. `SurrealValue.decode(_:)` and `SurrealValue.fromEncodable(_:)` now convert directly, keeping `Date`, `UUID`, `Data`, `Decimal`, `SurrealRecordID` and `SurrealValue` fields as SurrealDB types. Record ids, UUIDs, durations and datetimes still decode into `String` fields as their text form. The JSON-based variants that take a `JSONDecoder`/`JSONEncoder` remain, deprecated.
- Datetimes before 1970 were clamped to the epoch when sent. They're now sent as floored seconds plus forward-counting nanoseconds, as the server does, and malformed datetime tags throw instead of decoding to `NULL`.
- Durations decoded as `""`. The server sends tag 14 as `[seconds, nanoseconds]`, and the SDK only read a string; it now decodes that form into the server's canonical text (`1h30m`), and sends `.duration` values in the same form. Malformed duration tags now throw instead of decoding to an empty string. A `.duration` whose text isn't a duration now fails to encode with `EncodingError` instead of being sent as tag 13 (a duration as text), which SurrealDB 4.0 refuses. New `SurrealValue.duration(seconds:nanoseconds:)` and `durationComponents` convert between the two.

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
