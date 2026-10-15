import Foundation
import PotentCBOR
import Testing
@testable import SurrealDB

private struct Document: Codable, Sendable, Equatable {
    let name: String
    let file: SurrealFileRef
}

@Test
func fileRef_roundTripsThroughCBORTag55() throws {
    let file = SurrealFileRef(bucket: "docs", key: "/reports/q1.pdf")
    let cbor = CBORSurrealCodec.toCBOR(.file(file))
    #expect(cbor == .tagged(CBOR.Tag(rawValue: 55), .array([.utf8String("docs"), .utf8String("/reports/q1.pdf")])))
    #expect(try CBORSurrealCodec.fromCBOR(cbor) == .file(file))
    #expect(throws: SurrealError.self) {
        _ = try CBORSurrealCodec.fromCBOR(.tagged(CBOR.Tag(rawValue: 55), .utf8String("docs:/x")))
    }
}

@Test
func fileRef_codableAndLiteral() throws {
    let file = SurrealFileRef(bucket: "docs", key: "/a \"b\".txt")
    let value = try SurrealValue.fromEncodable(Document(name: "a", file: file))
    #expect(value == .object(["name": .string("a"), "file": .file(file)]))
    #expect(try value.decode(Document.self) == Document(name: "a", file: file))
    #expect(try SurrealValue.file(file).decode(String.self) == "docs:/a \"b\".txt")
    #expect(SurrealValue.file(file).sqlLiteral == #"f"docs:/a \"b\".txt""#)
}

/// Files are experimental: the server must run with
/// `SURREAL_CAPS_ALLOW_EXPERIMENTAL=files`, as the integration scripts do.
@Test
func integration_fileRefsRoundTripThroughTheServer() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        let probe = try await client.queryRaw(#"RETURN f"docs:/probe.txt";"#).first
        guard probe?.status == .ok else {
            Issue.record("Start the server with SURREAL_CAPS_ALLOW_EXPERIMENTAL=files to run the file tests.")
            return
        }
        #expect(probe?.result == .file(SurrealFileRef(bucket: "docs", key: "/probe.txt")))

        _ = try await client.queryRaw(#"DEFINE BUCKET docs BACKEND "memory";"#)
        let file = SurrealFileRef(bucket: "docs", key: "/notes/hello.txt")
        // A bound file value works as a file in SurrealQL.
        _ = try await client.queryRaw("$f.put(\"hello\");", bindings: ["f": .file(file)])
        let contents = try await client.queryRaw("RETURN <string> $f.get();", bindings: ["f": .file(file)]).first?.result
        #expect(contents == .string("hello"))

        // And comes back as one, in a typed record.
        _ = try await client.queryRaw("CREATE doc:1 CONTENT $d;", bindings: ["d": try .fromEncodable(Document(name: "hello", file: file))])
        let stored = try await client.query(SurrealQuery<Document>(sql: "SELECT name, file FROM doc:1;", bindings: [:]))
        #expect(stored == [Document(name: "hello", file: file)])
    }
}
