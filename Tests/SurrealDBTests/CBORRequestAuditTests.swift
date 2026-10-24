import Foundation
import Testing
@testable import SurrealDB

/// Reads an encoded CBOR item the way SurrealDB 4.0 reads a request, and
/// records what it would refuse: tags it doesn't read (0, 9 and 13 among
/// them: a datetime, uuid and duration as text), integers outside `i64`,
/// duplicate map keys, tag 6 around anything but null, and a uuid that isn't
/// 16 raw bytes.
struct CBORRequestAudit {
    /// Every tag the item uses.
    private(set) var tags: Set<UInt64> = []
    private(set) var problems: [String] = []

    /// The tags 4.0 reads in a request.
    static let accepted: Set<UInt64> = [6, 7, 8, 10, 12, 14, 37, 49, 50, 51, 55, 56, 88, 89, 90, 91, 92, 93, 94]

    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) {
        bytes = Array(data)
        item("$")
        if position != bytes.count {
            problems.append("\(bytes.count - position) trailing bytes")
        }
    }

    private mutating func head() -> (major: UInt8, argument: UInt64)? {
        guard position < bytes.count else {
            problems.append("truncated")
            return nil
        }
        let initial = bytes[position]
        position += 1
        let major = initial >> 5
        let info = initial & 0x1f
        let width: Int
        switch info {
        case 0..<24: return (major, UInt64(info))
        case 24: width = 1
        case 25: width = 2
        case 26: width = 4
        case 27: width = 8
        default:
            problems.append("indefinite or reserved length at \(position - 1)")
            return nil
        }
        guard position + width <= bytes.count else {
            problems.append("truncated")
            position = bytes.count
            return nil
        }
        var value: UInt64 = 0
        for byte in bytes[position..<(position + width)] {
            value = value << 8 | UInt64(byte)
        }
        position += width
        return (major, value)
    }

    /// `wide` lets the integers directly inside tag 14 reach `u64`: a
    /// duration's seconds do.
    private mutating func item(_ path: String, wide: Bool = false) {
        guard let (major, argument) = head() else { return }
        switch major {
        case 0:
            if !wide && argument > UInt64(Int64.max) {
                problems.append("integer \(argument) is outside i64 at \(path)")
            }
        case 1:
            if !wide && argument > UInt64(Int64.max) {
                problems.append("integer -1-\(argument) is outside i64 at \(path)")
            }
        case 2, 3:
            guard argument <= UInt64(bytes.count - position) else {
                problems.append("truncated")
                position = bytes.count
                return
            }
            position += Int(argument)
        case 4:
            var index: UInt64 = 0
            while index < argument && position < bytes.count {
                item("\(path)[\(index)]", wide: wide)
                index += 1
            }
        case 5:
            var seen = Set<[UInt8]>()
            var index: UInt64 = 0
            while index < argument && position < bytes.count {
                let start = position
                item("\(path).<key>")
                if !seen.insert(Array(bytes[start..<min(position, bytes.count)])).inserted {
                    problems.append("duplicate map key at \(path)")
                }
                item("\(path).<value>")
                index += 1
            }
        case 6:
            tags.insert(argument)
            if !Self.accepted.contains(argument) {
                problems.append("tag \(argument) is refused at \(path)")
            }
            let content = position
            item("\(path)<\(argument)>", wide: argument == 14)
            guard content < bytes.count else { return }
            if argument == 6 && bytes[content] != 0xf6 {
                problems.append("tag 6 holds something other than null at \(path)")
            }
            if argument == 37 && bytes[content] != 0x50 {
                problems.append("tag 37 isn't 16 bytes at \(path)")
            }
        default:
            break
        }
    }
}

private func audited(_ params: [SurrealValue], session: String? = nil, txn: String? = nil) throws -> CBORRequestAudit {
    CBORRequestAudit(try CBORSurrealCodec.encode(RPCRequest(id: "1", method: "query", params: params, session: session, txn: txn)))
}

@Test
func cborAudit_flagsEverythingFourPointZeroRefuses() {
    func problems(_ hex: String) -> [String] {
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        return CBORRequestAudit(Data(bytes)).problems
    }

    #expect(!problems("c060").isEmpty)  // tag 0: a datetime as text
    #expect(!problems("c960").isEmpty)  // tag 9: a uuid as text
    #expect(!problems("cd60").isEmpty)  // tag 13: a duration as text
    #expect(!problems("1bffffffffffffffff").isEmpty)  // above i64
    #expect(!problems("3bffffffffffffffff").isEmpty)  // below i64
    #expect(!problems("a2616101616102").isEmpty)  // {"a": 1, "a": 2}
    #expect(!problems("c601").isEmpty)  // tag 6 around 1
    #expect(!problems("d82560").isEmpty)  // tag 37 around text

    #expect(problems("c6f6").isEmpty)  // tag 6 around null
    #expect(problems("a2616101616202").isEmpty)  // {"a": 1, "b": 2}
    #expect(problems("1b7fffffffffffffff").isEmpty)  // i64::MAX
    #expect(problems("ce811bffffffffffffffff").isEmpty)  // a duration of u64::MAX seconds
}

@Test
func cborAudit_requestsNeverUseTheTagsFourPointZeroRefuses() throws {
    let uuid = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    let values: [SurrealValue] = [
        .none, .null, .bool(true), .int(Int64.max), .int(Int64.min), .double(.nan), .double(.infinity),
        .string("2024-01-02T03:04:05Z"), .bytes(Data([0, 1, 2])),
        .datetime(Date(timeIntervalSince1970: 0)),
        .datetime(Date(timeIntervalSince1970: 1_704_164_645.123456)),
        .datetime(Date(timeIntervalSince1970: -86_400.5)),
        .datetime(.distantPast), .datetime(.distantFuture),
        .uuid(uuid),
        .duration("1h30m"), .duration("0s"), .duration("250ns"), .duration("1y2w3d"),
        .duration(seconds: UInt64.max),
        .decimal("123.456"),
        .recordID(SurrealRecordID(table: "t", id: .uuid(uuid))),
        .recordID(SurrealRecordID(table: "t", id: .array([.datetime(Date()), .duration("5ms")]))),
        .range(SurrealRange(begin: .included(.datetime(Date(timeIntervalSince1970: 5))), end: .excluded(.duration("9s")))),
        .set([.int(1), .uuid(uuid)]),
        .geometry(.point([1, 2])),
        .array([.none, .uuid(uuid), .duration("1s")]),
        .object(["a": .datetime(Date()), "b": .array([.uuid(uuid), .none]), "c": .object(["d": .duration("2m")])]),
    ]

    let audit = try audited(values, session: uuid.uuidString.lowercased(), txn: uuid.uuidString.lowercased())
    #expect(audit.problems.isEmpty, "\(audit.problems)")
    #expect(audit.tags.isDisjoint(with: [0, 9, 13]))
    // And they do use the forms 4.0 asks for.
    #expect(audit.tags.isSuperset(of: [6, 12, 14, 37]))
}

@Test
func cborAudit_encodedSwiftValuesStayWithinI64AndKeepTheirTypes() throws {
    struct Row: Encodable {
        var date: Date
        var id: UUID
        var big: UInt64
        var biggest: UInt
        var decimal: Decimal
        var data: Data
        var missing: String?
        var byName: [String: Date]
    }

    let row = Row(
        date: Date(timeIntervalSince1970: 1_700_000_000.5),
        id: UUID(),
        big: UInt64.max,
        biggest: UInt.max,
        decimal: Decimal(string: "1.5")!,
        data: Data([1, 2, 3]),
        missing: nil,
        byName: ["a": Date(timeIntervalSince1970: 0), "A": Date(timeIntervalSince1970: 1), "a ": Date(timeIntervalSince1970: 2)]
    )
    let values: [SurrealValue] = [
        try SurrealValue.fromEncodable(row),
        try SurrealValue.fromEncodable(UInt64(1) << 63),
        try SurrealValue.fromEncodable(UInt64.max),
        try SurrealValue.fromEncodable([UInt64.max, 5]),
        try SurrealValue.fromEncodable(Date(timeIntervalSince1970: 1)),
        try SurrealValue.fromEncodable(UUID()),
    ]

    let audit = try audited(values)
    #expect(audit.problems.isEmpty, "\(audit.problems)")
    #expect(audit.tags.isDisjoint(with: [0, 9, 13]))
    // An unsigned value above i64::MAX has no integer form: it goes as a decimal (tag 10).
    #expect(audit.tags.isSuperset(of: [10, 12, 37]))
}
