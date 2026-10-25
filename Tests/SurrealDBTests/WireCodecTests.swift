import Foundation
import Testing
@testable import SurrealDB

@Test
func jsonWireCodec_roundTripsRequestAndEnvelope() throws {
    let codec = JSONWireCodec()

    let request = RPCRequest(
        id: "abc",
        method: "query",
        params: [.string("SELECT * FROM person;"), .object(["limit": .int(10)])],
        session: nil,
        txn: nil
    )

    let encoded = try codec.encode(request)
    #expect(!encoded.isEmpty)

    let payload = String(data: encoded, encoding: .utf8) ?? ""
    #expect(payload.contains("\"id\":\"abc\""))
    #expect(payload.contains("\"method\":\"query\""))

    let responseJSON = """
    {
      "id": "abc",
      "result": [
        {
          "status": "OK",
          "time": "1ms",
          "result": [{"name": "Ada"}],
          "type": "other"
        }
      ]
    }
    """
    let envelope = try codec.decodeEnvelope(Data(responseJSON.utf8))
    #expect(envelope.id == "abc")
    #expect(envelope.error == nil)

    let rows = try codec.decodeQueryResults(from: envelope.result ?? .null)
    #expect(rows.count == 1)
    #expect(rows[0].status == .ok)
}

@Test
func jsonWireCodec_encodesSessionAndTxnFieldsWhenPresent() throws {
    let codec = JSONWireCodec()
    let sessionID = UUID().uuidString
    let txnID = UUID().uuidString

    let request = RPCRequest(
        id: "1",
        method: "query",
        params: [.string("SELECT 1;"), .object([:])],
        session: sessionID,
        txn: txnID
    )

    let encoded = try codec.encode(request)
    let payload = String(data: encoded, encoding: .utf8) ?? ""

    #expect(payload.contains("\"session\":\"\(sessionID)\""))
    #expect(payload.contains("\"txn\":\"\(txnID)\""))
}

@Test
func jsonWireCodec_omitsSessionAndTxnFieldsWhenNil() throws {
    let codec = JSONWireCodec()
    let request = RPCRequest(
        id: "1",
        method: "query",
        params: [.string("SELECT 1;"), .object([:])],
        session: nil,
        txn: nil
    )

    let encoded = try codec.encode(request)
    let payload = String(data: encoded, encoding: .utf8) ?? ""

    #expect(!payload.contains("\"session\""))
    #expect(!payload.contains("\"txn\""))
}

@Test
func jsonWireCodec_decodesErrorEnvelope() throws {
    let codec = JSONWireCodec()
    let responseJSON = """
    {
      "id": "1",
      "error": {
        "code": -32000,
        "message": "boom"
      }
    }
    """
    let envelope = try codec.decodeEnvelope(Data(responseJSON.utf8))
    #expect(envelope.error?.code == -32000)
    #expect(envelope.error?.message == "boom")
}

@Test
func cborWireCodec_exposesSubprotocolAndContentType() {
    let codec = CBORWireCodec()
    #expect(codec.httpContentType == "application/cbor")
    #expect(codec.httpAccept == "application/cbor; v=2")
    #expect(codec.websocketSubprotocols == ["cbor.2", "cbor"])

    let plain = CBORWireCodec(offersCBOR2: false)
    #expect(plain.httpAccept == "application/cbor")
    #expect(plain.websocketSubprotocols == ["cbor"])
}

@Test
func jsonWireCodec_exposesSubprotocolAndContentType() {
    let codec = JSONWireCodec()
    #expect(codec.httpContentType == "application/json")
    #expect(codec.websocketSubprotocols == ["json"])
}

@Test
func surrealTransaction_buildsBeginCommitWrapper() {
    let tx = SurrealTransaction()
    tx.append("CREATE person CONTENT $a", bindings: ["a": .object(["name": .string("Ada")])])
    tx.append("UPDATE person SET age = 31 WHERE name = $a", bindings: ["a": .string("Ada")])

    let (sql, bindings) = tx.build()
    #expect(sql.hasPrefix("BEGIN;\n"))
    #expect(sql.hasSuffix("COMMIT;"))
    // Two distinct values for $a — second one should be renamed.
    #expect(bindings.count == 2)
    let aValue = bindings["a"]
    #expect(aValue == .object(["name": .string("Ada")]))
    // The rewritten statement should reference the renamed binding.
    #expect(sql.contains("$a_tx"))
}

@Test
func surrealTransaction_keepsSharedBindingsWhenEqual() {
    let tx = SurrealTransaction()
    tx.append("RETURN $x;", bindings: ["x": .int(1)])
    tx.append("RETURN $x;", bindings: ["x": .int(1)])

    let (sql, bindings) = tx.build()
    #expect(bindings.count == 1)
    #expect(bindings["x"] == .int(1))
    // Both statements still reference $x (no rename when values are equal).
    let occurrences = sql.components(separatedBy: "$x").count - 1
    #expect(occurrences == 2)
}
