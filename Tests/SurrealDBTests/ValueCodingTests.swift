import Foundation
import PotentCBOR
import Testing
@testable import SurrealDB

private struct Rich: Codable, Equatable {
    var id: SurrealRecordID?
    var owner: SurrealRecordID
    var at: Date
    var token: UUID
    var blob: Data
    var price: Decimal
    var wait: SurrealValue
    var tags: [String]
    var nested: Nested
    var maybe: Int?

    struct Nested: Codable, Equatable {
        var count: Int
        var ratio: Double
    }
}

private struct StringIDModel: Codable {
    var id: String
    var token: String
    var at: String
}

@Test
func valueCoding_encodesSurrealTypesDirectly() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
    let token = UUID()
    let value = try SurrealValue.fromEncodable(Rich(
        id: SurrealRecordID(table: "rich", id: .string("a")),
        owner: SurrealRecordID(table: "user", id: .int(7)),
        at: date,
        token: token,
        blob: Data([1, 2, 3]),
        price: Decimal(string: "12.50")!,
        wait: .duration("1h"),
        tags: ["x"],
        nested: .init(count: 2, ratio: 0.5),
        maybe: nil
    ))

    guard case .object(let object) = value else {
        Issue.record("Expected an object, got \(value)")
        return
    }
    #expect(object["id"] == .recordID(SurrealRecordID(table: "rich", id: .string("a"))))
    #expect(object["owner"] == .recordID(SurrealRecordID(table: "user", id: .int(7))))
    #expect(object["at"] == .datetime(date))
    #expect(object["token"] == .uuid(token))
    #expect(object["blob"] == .bytes(Data([1, 2, 3])))
    #expect(object["price"] == .decimal("12.5"))
    #expect(object["wait"] == .duration("1h"))
    #expect(object["tags"] == .array([.string("x")]))
    #expect(object["nested"] == .object(["count": .int(2), "ratio": .double(0.5)]))
    #expect(object["maybe"] == nil)
}

@Test
func valueCoding_decodesSurrealTypesDirectly() throws {
    let date = Date(timeIntervalSince1970: -1_234.5)
    let token = UUID()
    let value: SurrealValue = .object([
        "id": .recordID(SurrealRecordID(table: "rich", id: .string("a"))),
        "owner": .recordID(SurrealRecordID(table: "user", id: .int(7))),
        "at": .datetime(date),
        "token": .uuid(token),
        "blob": .bytes(Data([9])),
        "price": .decimal("0.1"),
        "wait": .duration("2m"),
        "tags": .set([.string("x"), .string("y")]),
        "nested": .object(["count": .int(3), "ratio": .int(1)]),
        "maybe": .none,
    ])

    let rich = try value.decode(Rich.self)
    #expect(rich.id == SurrealRecordID(table: "rich", id: .string("a")))
    #expect(rich.owner.id == .int(7))
    #expect(rich.at == date)
    #expect(rich.token == token)
    #expect(rich.blob == Data([9]))
    #expect(rich.price == Decimal(string: "0.1"))
    #expect(rich.wait == .duration("2m"))
    #expect(rich.tags == ["x", "y"])
    #expect(rich.nested == .init(count: 3, ratio: 1))
    #expect(rich.maybe == nil)
}

@Test
func valueCoding_decodesRichTypesIntoStrings() throws {
    // Models declaring `id: String` keep working.
    let token = UUID()
    let model = try SurrealValue.object([
        "id": .recordID(SurrealRecordID(table: "person", id: .string("alice"))),
        "token": .uuid(token),
        "at": .datetime(Date(timeIntervalSince1970: 0.25)),
    ]).decode(StringIDModel.self)
    #expect(model.id == "person:alice")
    #expect(model.token == token.uuidString.lowercased())
    #expect(model.at == "1970-01-01T00:00:00.250Z")
}

@Test
func valueCoding_rejectsLossyNumbers() {
    #expect(throws: DecodingError.self) { try SurrealValue.int(300).decode(UInt8.self) }
    #expect(throws: DecodingError.self) { try SurrealValue.double(1.5).decode(Int.self) }
    #expect(throws: DecodingError.self) { try SurrealValue.string("1").decode(Int.self) }
    #expect((try? SurrealValue.double(2).decode(Int.self)) == 2)
}

@Test
func valueCoding_keepsSurrealValueAsIs() throws {
    let raw: SurrealValue = .object(["id": .recordID(SurrealRecordID(table: "t", id: .int(1))), "d": .duration("1s")])
    #expect(try raw.decode(SurrealValue.self) == raw)
    #expect(try raw.decode([String: SurrealValue].self)["d"] == .duration("1s"))
    #expect(try SurrealValue.fromEncodable(raw) == raw)
}

@Test
func valueCoding_datetimeWireFormKeepsPre1970AndSubseconds() throws {
    let tag = CBORSurrealCodec.tagCustomDatetime

    // 1969-12-31T23:59:59.5Z: seconds floor to -1, nanoseconds count forwards.
    let before = Date(timeIntervalSince1970: -0.5)
    #expect(CBORSurrealCodec.toCBOR(.datetime(before)) == .tagged(tag, .array([.negativeInt(0), .unsignedInt(500_000_000)])))
    #expect(try CBORSurrealCodec.fromCBOR(.tagged(tag, .array([.negativeInt(0), .unsignedInt(500_000_000)]))) == .datetime(before))

    let old = Date(timeIntervalSince1970: -2_208_988_800) // 1900-01-01
    #expect(try CBORSurrealCodec.fromCBOR(CBORSurrealCodec.toCBOR(.datetime(old))) == .datetime(old))

    let precise = Date(timeIntervalSince1970: 1_700_000_000.123456)
    guard case .datetime(let decoded) = try CBORSurrealCodec.fromCBOR(CBORSurrealCodec.toCBOR(.datetime(precise))) else {
        Issue.record("Expected a datetime")
        return
    }
    #expect(abs(decoded.timeIntervalSince(precise)) < 0.000_001)

    #expect(throws: SurrealError.self) { try CBORSurrealCodec.fromCBOR(.tagged(tag, .array([.unsignedInt(1)]))) }
}

private class Base: Encodable {
    var a = 1
}

private final class Derived: Base {
    var b = 2
    private enum CodingKeys: String, CodingKey { case b }

    override func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(b, forKey: .b)
        // No `super` case in CodingKeys: this used to force-unwrap nil.
        try super.encode(to: container.superEncoder())
    }
}

private struct StrictNil: Decodable {
    let x: Int?
    private enum CodingKeys: String, CodingKey { case x }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeNil(forKey: .x) ? nil : try container.decode(Int.self, forKey: .x)
    }
}

@Test
func valueCoding_superEncoderWithoutSuperKey() throws {
    #expect(try SurrealValue.fromEncodable(Derived()) == .object(["b": .int(2), "super": .object(["a": .int(1)])]))
}

@Test
func valueCoding_rejectsValuesThatWouldChangeOrTrap() {
    #expect(throws: DecodingError.self) { _ = try SurrealValue.double(1e100).decode(Float.self) }
    #expect(throws: DecodingError.self) { _ = try SurrealValue.double(.infinity).decode(Decimal.self) }
    #expect(throws: DecodingError.self) { _ = try SurrealValue.double(-.infinity).decode(Decimal.self) }
    #expect(throws: DecodingError.self) { _ = try SurrealValue.decimal("12.5oops").decode(Decimal.self) }
    #expect(throws: DecodingError.self) { _ = try SurrealValue.object([:]).decode(StrictNil.self) }
    #expect((try? SurrealValue.double(.infinity).decode(Float.self)) == .infinity)
    #expect((try? SurrealValue.decimal("12.5").decode(Decimal.self)) == Decimal(string: "12.5"))
    #expect((try? SurrealValue.object(["x": .null]).decode(StrictNil.self)) != nil)
}

@Test
func valueCoding_datetimeSecondsNearInt64MinDoNotTrap() throws {
    let tag = CBOR.Tag(rawValue: 12)
    let value = try CBORSurrealCodec.fromCBOR(.tagged(tag, .array([CBORSurrealCodec.cborInteger(.min), .unsignedInt(0)])))
    guard case .datetime(let date) = value else {
        Issue.record("Expected a datetime")
        return
    }
    #expect(date.timeIntervalSince1970 < -9e18)
}
