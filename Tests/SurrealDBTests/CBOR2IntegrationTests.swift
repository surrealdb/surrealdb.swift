import Foundation
import Testing
@testable import SurrealDB

/// Whether the server is older than 4.0, which has neither cbor.2 nor the
/// sized numbers.
private func isBefore4(_ client: SurrealClient) async throws -> Bool {
    let version = try await client.version()
    return (Int(version.prefix { $0.isNumber }) ?? 0) < 4
}

@Test
func integration_cbor2IsNegotiatedOrFallsBack() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }

        // HTTP settles on a dialect with the first response.
        let rows = try await client.queryRaw("RETURN $v", bindings: ["v": .sized(.u8(5))])
        let dialect = await client.cborDialect()
        if try await isBefore4(client) {
            // A 3.x server picks cbor; the sized number went widened.
            #expect(dialect == .cbor, "\(endpoint)")
            #expect(rows.first?.result == .int(5), "\(endpoint)")
        } else {
            #expect(dialect == .cbor2, "\(endpoint)")
            #expect(rows.first?.result == .sized(.u8(5)), "\(endpoint)")
        }
    }
}

@Test
func integration_cbor2SizedNumbersKeepTheirWidth() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }
        _ = try await client.queryRaw("RETURN 1", bindings: [:])
        // Needs cbor.2, which servers before 4.0 don't negotiate.
        guard await client.cborDialect() == .cbor2 else { continue }

        let rows = try await client.queryRaw(
            "RETURN [5u8, -3i16, 18446744073709551615u64, 1.5f32, <f16>NaN]; RETURN type::of($v); RETURN $v",
            bindings: ["v": .sized(.u8(200))]
        )
        #expect(rows.count == 3)
        guard rows.count == 3, case .array(let values) = rows[0].result, values.count == 5 else {
            Issue.record("Unexpected result \(rows)")
            continue
        }
        #expect(values[0] == .sized(.u8(5)))
        #expect(values[1] == .sized(.i16(-3)))
        #expect(values[2] == .sized(.u64(.max)))
        #expect(values[3] == .sized(.f32(1.5)))
        if case .sized(.f16(let half)) = values[4] { #expect(half.isNaN) } else { Issue.record("Expected an f16, got \(values[4])") }
        // The parameter kept its width on the way in, too.
        #expect(rows[1].result == .string("u8"))
        #expect(rows[2].result == .sized(.u8(200)))
    }
}

@Test
func integration_cbor2PlainCBORWidensSizedNumbers() async throws {
    guard IntegrationEnv.enabled else { return }

    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint, options: .init(negotiatesCBOR2: false))
        defer { Task { await client.close() } }
        let rows = try await client.queryRaw("RETURN $v", bindings: ["v": .sized(.u64(.max))])
        #expect(await client.cborDialect() == .cbor)
        #expect(rows.first?.result == .decimal("18446744073709551615"), "\(endpoint)")
        // Sized literals need a 4.0 server.
        guard try await !isBefore4(client) else { continue }
        let widened = try await client.queryRaw("RETURN [5u8, 1.5f32]", bindings: [:])
        #expect(widened.first?.result == .array([.int(5), .double(1.5)]), "\(endpoint)")
    }
}

@Test
func integration_geometryRoundTripsInTheServersForm() async throws {
    guard IntegrationEnv.enabled else { return }

    // Points inside lines, lines inside polygons and so on each carry their
    // own tag; the server sends them so, and expects them so.
    let values: [SurrealValue] = [
        .geometry(.point([1.5, 2.5])),
        .geometry(.line([[0, 0], [1, 1], [2, 0]])),
        .geometry(.polygon([[[0, 0], [4, 0], [4, 4], [0, 0]]])),
        .geometry(.multiPoint([[0, 0], [1, 2]])),
        .geometry(.multiLine([[[0, 0], [1, 1]], [[2, 2], [3, 3]]])),
        .geometry(.multiPolygon([[[[0, 0], [1, 0], [1, 1], [0, 0]]]])),
        .geometry(.collection([.point([1, 2]), .line([[0, 0], [1, 1]])])),
    ]
    for endpoint in integrationEndpoints {
        let client = try await integrationClient(endpoint)
        defer { Task { await client.close() } }
        for value in values {
            let rows = try await client.queryRaw("RETURN [$v, type::is_geometry($v)]", bindings: ["v": value])
            #expect(rows.first?.result == .array([value, .bool(true)]), "\(endpoint) \(value)")
        }
        let line = try await client.queryRaw("RETURN { type: 'LineString', coordinates: [[0, 0], [1, 1]] }", bindings: [:])
        #expect(line.first?.result == .geometry(.line([[0, 0], [1, 1]])), "\(endpoint)")
    }
}
