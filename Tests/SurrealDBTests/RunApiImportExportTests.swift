import Foundation
import PotentCBOR
import Testing
@testable import SurrealDB

private struct Greeting: Decodable, Sendable, Equatable {
    let hello: String
    let q: [String: String]
    let got: [String: Int]
    let h: String
}

/// Answers every request with a 200 whose body is `ImportStub.body`, the way
/// servers before 3.3.1 answer `/import` even when statements failed.
private final class ImportStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test
func import_failedStatementsInA200AreReported() async throws {
    func row(_ status: String, _ result: SurrealValue) -> SurrealValue {
        .object(["status": .string(status), "time": .string("1ms"), "result": result])
    }
    ImportStub.body = try CBORSerialization.data(from: CBORSurrealCodec.toCBOR(.array([
        row("OK", .array([])),
        row("ERR", .string("Database record `keep:a` already exists")),
    ])))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImportStub.self]
    let endpoints = HTTPEndpoints(
        rpcURL: URL(string: "http://127.0.0.1:1/rpc")!,
        timeout: 5,
        urlSession: URLSession(configuration: configuration)
    )

    do {
        try await endpoints.importSQL("OPTION IMPORT; CREATE keep:z; CREATE keep:a;", session: SessionContext())
        Issue.record("Expected importFailed")
    } catch SurrealError.importFailed(let failures) {
        #expect(failures.map(\.index) == [0])
        #expect(failures.first?.message.contains("keep:a") == true)
    }

    // A 200 with an empty result list is a clean import.
    ImportStub.body = try CBORSerialization.data(from: CBORSurrealCodec.toCBOR(.array([])))
    try await endpoints.importSQL("OPTION IMPORT;", session: SessionContext())
}

@Test
func importExport_requireAConnectedClient() async throws {
    let client = try SurrealClient(endpoint: "http://127.0.0.1:1")
    do {
        try await client.import("OPTION IMPORT;")
        Issue.record("Expected notConnected before connect()")
    } catch SurrealError.notConnected {}
    do {
        _ = try await client.export()
        Issue.record("Expected notConnected before connect()")
    } catch SurrealError.notConnected {}
}

@Test
func integration_importAfterCloseThrowsNotConnected() async throws {
    guard IntegrationEnv.enabled else { return }

    let client = try await integrationClient(httpEndpoint())
    await client.close()
    do {
        _ = try await client.export()
        Issue.record("Expected notConnected after close()")
    } catch SurrealError.notConnected {}
}

@Test
func exportOptions_onlySendsWhatWasSet() throws {
    #expect(SurrealExportOptions().jsonObject.isEmpty)
    let only = SurrealExportOptions(tables: .only(["a", "b"]), records: false).jsonObject
    #expect(only["tables"] as? [String] == ["a", "b"])
    #expect(only["records"] as? Bool == false)
    #expect(only.count == 2)
    let excluding = SurrealExportOptions(tables: .excluding(["c"])).jsonObject
    #expect((excluding["tables"] as? [String: [String]]) == ["exclude": ["c"]])
    #expect(SurrealExportOptions(tables: SurrealExportOptions.Tables.none).jsonObject["tables"] as? Bool == false)
}

@Test
func apiResponse_decodesStatusHeadersAndBody() throws {
    let response = try SurrealAPIResponse(.object([
        "status": .int(201),
        "headers": .object(["x-out": .string("yes")]),
        "body": .object(["n": .int(1)]),
        "request_id": .string("r"),
    ]))
    #expect(response.status == 201)
    #expect(response.headers == ["x-out": "yes"])
    #expect(try response.body(as: [String: Int].self) == ["n": 1])
    #expect(throws: SurrealError.self) { try SurrealAPIResponse(.string("nope")) }
}

@Test
func integration_runCallsFunctions() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        #expect(try await client.run("string::len", arguments: [.string("abcd")]) == .int(4))
        _ = try await client.queryRaw(#"DEFINE FUNCTION fn::greet($name: string) { RETURN "hi " + $name; };"#)
        #expect(try await client.run("fn::greet", arguments: [.string("ada")], as: String.self) == "hi ada")
        await #expect(throws: SurrealError.self) {
            _ = try await client.run("fn::missing")
        }
    }
}

@Test
func integration_apiInvokesDefinedEndpoints() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        _ = try await client.queryRaw("""
            DEFINE API "/greet/:name" FOR get, post THEN {
                RETURN {
                    status: 201,
                    body: { hello: $request.params.name, q: $request.query, got: $request.body, h: $request.headers["x-test"] },
                    headers: { "x-out": "yes" }
                };
            };
            """)

        let response = try await client.api(
            "/greet/ada",
            method: .post,
            body: .object(["a": .int(1)]),
            headers: ["x-test": "t"],
            query: ["k": "v"]
        )
        #expect(response.status == 201)
        #expect(response.headers["x-out"] == "yes")
        #expect(try response.body(as: Greeting.self) == Greeting(hello: "ada", q: ["k": "v"], got: ["a": 1], h: "t"))

        // Not defined for this method or path: a 404, not a thrown error.
        #expect(try await client.api("/greet/ada", method: .delete).status == 404)
        #expect(try await client.api("/missing").status == 404)
    }
}

@Test
func integration_exportThenImportIntoAnotherDatabase() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let source = try await integrationClient(endpoint)
        defer { Task { await source.close() } }
        _ = try await source.queryRaw("""
            DEFINE TABLE keep SCHEMALESS;
            DEFINE TABLE skip SCHEMALESS;
            CREATE keep:a SET v = 1;
            CREATE keep:b SET v = 2;
            CREATE skip:c SET v = 3;
            DEFINE FUNCTION fn::f() { RETURN 1; };
            """)

        let everything = try await source.export()
        #expect(everything.contains("OPTION IMPORT;"))
        #expect(everything.contains("fn::f"))
        #expect(everything.contains("skip:c"))

        let dump = try await source.export(SurrealExportOptions(tables: .only(["keep"]), functions: false))
        #expect(dump.contains("keep:a"))
        #expect(!dump.contains("skip:c"))
        #expect(!dump.contains("fn::f"))

        let target = try await integrationClient(endpoint)
        defer { Task { await target.close() } }
        try await target.import(dump)
        let rows = try await target.queryRaw("SELECT VALUE v FROM keep ORDER BY v;").first?.result
        #expect(rows == .array([.int(1), .int(2)]))

        // Importing again: the records exist, so those statements fail and
        // the error lists them; nothing else is undone.
        do {
            try await target.import("OPTION IMPORT; CREATE keep:a SET v = 9; CREATE keep:z SET v = 26;")
            Issue.record("Expected importFailed")
        } catch SurrealError.importFailed(let failures) {
            #expect(failures.count == 1)
            #expect(failures.first?.message.contains("keep:a") == true)
        }
        #expect(try await target.queryRaw("SELECT VALUE v FROM keep:z;").first?.result == .array([.int(26)]))

        // A body that isn't an import dump is refused before anything runs.
        await #expect(throws: SurrealError.self) {
            try await target.import("CREATE keep:y;")
        }
    }
}
