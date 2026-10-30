import Foundation
import PotentCBOR
import PotentYAML
@testable import SurrealDB
import SurrealConformance
import Testing

/// The CBOR value vectors from surrealdb-protocol (spec/vectors/cbor.yaml and
/// cbor2.yaml), checked against the codec as spec/README.md describes.
///
/// The vectors aren't copied into this repository. `scripts/fetch-surrealdb-protocol.sh`
/// checks out the pinned tag into `.build/surrealdb-protocol`, and CI does the
/// same; set `SURREALDB_PROTOCOL_DIR` to use another checkout. Without one
/// these tests are skipped, unless `SURREALDB_PROTOCOL_DIR` is set, in which
/// case a missing file fails them.
@Suite("Conformance vectors")
struct ConformanceVectorTests {
    @Test("cbor.yaml as plain cbor", .enabled(if: ConformanceVectors.available), arguments: ConformanceVectors.load("cbor.yaml"))
    func cborVector(_ vector: ConformanceVector) throws {
        try check(vector, dialect: .cbor)
    }

    @Test(
        "cbor.yaml as cbor.2",
        .enabled(if: ConformanceVectors.available),
        arguments: ConformanceVectors.load("cbor.yaml").filter { $0.formats.map { $0.contains("cbor.2") } ?? true }
    )
    func cborVectorOverCBOR2(_ vector: ConformanceVector) throws {
        try check(vector, dialect: .cbor2)
    }

    @Test("cbor2.yaml as cbor.2", .enabled(if: ConformanceVectors.available), arguments: ConformanceVectors.load("cbor2.yaml"))
    func cbor2Vector(_ vector: ConformanceVector) throws {
        try check(vector, dialect: .cbor2)
    }

    /// Every vector in cbor2.yaml carries a sized-number tag, so plain cbor
    /// must refuse each one.
    @Test("cbor2.yaml refused as plain cbor", .enabled(if: ConformanceVectors.available), arguments: ConformanceVectors.load("cbor2.yaml"))
    func cbor2VectorRefusedOverCBOR(_ vector: ConformanceVector) throws {
        #expect(throws: (any Error).self) {
            try CBORSurrealCodec.decodeValue(vector.cbor, dialect: .cbor)
        }
    }

    @Test("The checkout is the pinned tag", .enabled(if: ConformanceVectors.available))
    func pinnedTag() throws {
        let version = try String(contentsOf: ConformanceVectors.directory.appendingPathComponent("package.json"), encoding: .utf8)
        #expect(version.contains("\"version\": \"\(ConformanceVectors.pinnedVersion)\""))
    }

    private func check(_ vector: ConformanceVector, dialect: CBORDialect) throws {
        let gap = ConformanceVectors.knownGaps[vector.name]
        try withKnownIssue(Comment(rawValue: gap ?? ""), isIntermittent: false) {
            try checkVector(vector, dialect: dialect)
        } when: {
            gap != nil
        }
    }

    private func checkVector(_ vector: ConformanceVector, dialect: CBORDialect) throws {
        switch vector.kind {
        case "canonical", "decode":
            let expected = try TypedJSON.value(from: #require(vector.value))
            let decoded = try CBORSurrealCodec.decodeValue(vector.cbor, dialect: dialect)
            #expect(TypedJSON.equal(decoded, expected), "decoded \(decoded), expected \(expected)")
            if vector.kind == "canonical" {
                let encoded = try encode(expected, dialect: dialect)
                let roundTripped = try CBORSurrealCodec.decodeValue(encoded, dialect: dialect)
                #expect(TypedJSON.equal(roundTripped, expected), "round trip gave \(roundTripped), expected \(expected)")
            }
        case "reject":
            #expect(throws: (any Error).self, "decoded to a value") {
                try CBORSurrealCodec.decodeValue(vector.cbor, dialect: dialect)
            }
        default:
            Issue.record("Unknown vector kind \(vector.kind)")
        }
    }

    private func encode(_ value: SurrealValue, dialect: CBORDialect) throws -> Data {
        try CBORSurrealCodec.checkEncodable(value)
        return try CBORSerialization.data(from: CBORSurrealCodec.toCBOR(value, dialect: dialect))
    }
}

struct ConformanceVector: Sendable, CustomTestStringConvertible {
    let name: String
    let kind: String
    let cbor: Data
    let value: JSONValue?
    let formats: [String]?

    var testDescription: String { name }
}

enum ConformanceVectors {
    /// The surrealdb-protocol release these tests are pinned to. Bump it
    /// together with the tag in scripts/fetch-surrealdb-protocol.sh and
    /// .github/workflows/ci.yml.
    static let pinnedVersion = "0.14.0"

    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["SURREALDB_PROTOCOL_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/surrealdb-protocol")
    }()

    static var available: Bool {
        ProcessInfo.processInfo.environment["SURREALDB_PROTOCOL_DIR"] != nil
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("spec/vectors/cbor.yaml").path)
    }

    /// Vectors the codec doesn't pass yet, with why. Each is a known issue,
    /// so the suite fails if one starts passing and should come off the list.
    static let knownGaps: [String: String] = [:]

    static func load(_ file: String) -> [ConformanceVector] {
        guard available else { return [] }
        let url = directory.appendingPathComponent("spec/vectors").appendingPathComponent(file)
        do {
            let yaml = try YAMLSerialization.yaml(from: Data(contentsOf: url))
            guard case .sequence(let entries, _, _, _)? = yaml.mappingValue?.first(where: { $0.key.stringValue == "vectors" })?.value else {
                throw TypedJSON.Error("no vectors list in \(file)")
            }
            return try entries.map(vector)
        } catch {
            // Surfaces as a failing test rather than a crash at discovery.
            return [ConformanceVector(name: "load \(file): \(error)", kind: "unreadable", cbor: Data(), value: nil, formats: nil)]
        }
    }

    private static func vector(_ yaml: YAML) throws -> ConformanceVector {
        guard let fields = yaml.mappingValue else { throw TypedJSON.Error("a vector is not a mapping") }
        func field(_ name: String) -> YAML? {
            fields.first { $0.key.stringValue == name }?.value
        }
        guard let name = field("name").flatMap(scalarText), let kind = field("kind")?.stringValue,
              let hex = field("cbor").flatMap(scalarText)
        else {
            throw TypedJSON.Error("a vector needs name, kind and cbor")
        }
        return ConformanceVector(
            name: name,
            kind: kind,
            cbor: try TypedJSON.bytes(fromHex: hex),
            value: try field("value").map(json),
            formats: field("formats")?.sequenceValue?.compactMap(\.stringValue)
        )
    }

    /// A scalar's text whatever YAML made of it: hex such as `1864` reads
    /// as an integer.
    private static func scalarText(_ yaml: YAML) -> String? {
        switch yaml {
        case .string(let text, _, _, _): text
        case .integer(let number, _), .float(let number, _): number.value
        case .bool(let value, _): String(value)
        case .null: "null"
        default: nil
        }
    }

    static func json(_ yaml: YAML) throws -> JSONValue {
        switch yaml {
        case .null:
            return .null
        case .bool(let value, _):
            return .bool(value)
        case .string(let text, _, _, _):
            return .string(text)
        case .integer(let number, _):
            return .integer(number.value.hasPrefix("+") ? String(number.value.dropFirst()) : number.value)
        case .float(let number, _):
            guard let value = number.doubleValue else { throw TypedJSON.Error("bad float \(number.value)") }
            return .float(value)
        case .sequence(let values, _, _, _):
            return .array(try values.map(json))
        case .mapping(let entries, _, _, _):
            var object: [String: JSONValue] = [:]
            for entry in entries {
                guard let key = scalarText(entry.key) else { throw TypedJSON.Error("a non-scalar key") }
                object[key] = try json(entry.value)
            }
            return .object(object)
        case .alias:
            throw TypedJSON.Error("YAML aliases are not used in the vectors")
        }
    }
}
