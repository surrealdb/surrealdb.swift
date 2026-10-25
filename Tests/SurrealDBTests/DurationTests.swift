import Foundation
import PotentCBOR
import Testing
@testable import SurrealDB

private func decode(_ cbor: CBOR) throws -> SurrealValue {
    try CBORSurrealCodec.fromCBOR(cbor)
}

@Test
func duration_decodesServerSecondsNanosForm() throws {
    // The server sends tag 14 as [seconds, nanoseconds], dropping trailing zeros.
    let tag = CBORSurrealCodec.tagCustomDuration
    #expect(try decode(.tagged(tag, .array([.unsignedInt(5400)]))) == .duration("1h30m"))
    #expect(try decode(.tagged(tag, .array([.unsignedInt(1), .unsignedInt(500_000_000)]))) == .duration("1s500ms"))
    #expect(try decode(.tagged(tag, .array([]))) == .duration("0ns"))
    #expect(try decode(.tagged(tag, .array([.unsignedInt(0), .unsignedInt(1)]))) == .duration("1ns"))
    #expect(try decode(.tagged(tag, .array([.unsignedInt(UInt64(400 * 86_400))]))) == .duration("1y5w"))
}

@Test
func duration_rejectsMalformedTag14() {
    let tag = CBORSurrealCodec.tagCustomDuration
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .utf8String("1h"))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .array([.negativeInt(0)]))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .array([.unsignedInt(1), .unsignedInt(UInt64(UInt32.max) + 1)]))) }
    // The server's nanoseconds are always under a second.
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .array([.unsignedInt(UInt64.max), .unsignedInt(1_000_000_000)]))) }
}

@Test
func duration_componentsAtTheLimitsDoNotTrap() {
    // Used to trap adding the carried second to UInt64.max seconds.
    let huge = SurrealValue.duration(seconds: UInt64.max, nanoseconds: UInt32.max)
    guard case .duration(let text) = huge else {
        Issue.record("Expected a duration")
        return
    }
    #expect(text.hasSuffix("4294ms967µs295ns"))
    // Too long to represent as seconds and nanoseconds, so parsing gives nil
    // rather than trapping.
    #expect(huge.durationComponents == nil)
    #expect(SurrealValue.duration("584942417356y").durationComponents == nil)

    // Below the limit, extra nanoseconds still carry into seconds.
    #expect(SurrealValue.duration(seconds: 1, nanoseconds: 1_500_000_000) == .duration("2s500ms"))
}

@Test
func duration_stringFormIsRefused() {
    // Tag 13 is the text form, which servers never send and 4.0 refuses.
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagStringDuration, .utf8String("2w"))) }
}

@Test
func duration_encodesAsSecondsNanos() {
    let tag = CBORSurrealCodec.tagCustomDuration
    #expect(CBORSurrealCodec.toCBOR(.duration("1h30m")) == .tagged(tag, .array([.unsignedInt(5400)])))
    #expect(CBORSurrealCodec.toCBOR(.duration("1s500ms")) == .tagged(tag, .array([.unsignedInt(1), .unsignedInt(500_000_000)])))
    #expect(CBORSurrealCodec.toCBOR(.duration("0s")) == .tagged(tag, .array([])))
    // Text that isn't a duration has no tag 14 form, so it isn't sent.
    #expect(throws: EncodingError.self) {
        _ = try CBORSurrealCodec.encode(RPCRequest(id: "1", method: "query", params: [.duration("soon")], session: nil, txn: nil))
    }
}

@Test
func duration_textRoundTrips() {
    for text in ["0ns", "1ns", "1µs", "999ms", "1s500ms", "1h30m", "1y2w3d4h5m6s7ms8µs9ns"] {
        let parts = SurrealValue.duration(text).durationComponents
        #expect(parts != nil)
        if let parts {
            #expect(SurrealValue.duration(seconds: parts.seconds, nanoseconds: parts.nanoseconds) == .duration(text))
        }
    }
    #expect(SurrealValue.duration("90m").durationComponents?.seconds == 5400)
    #expect(SurrealValue.duration("1500ms").durationComponents?.nanoseconds == 500_000_000)
    #expect(SurrealValue.duration("1us").durationComponents?.nanoseconds == 1_000)
    #expect(SurrealValue.duration("").durationComponents == nil)
    #expect(SurrealValue.duration("1x").durationComponents == nil)
    #expect(SurrealValue.duration("h").durationComponents == nil)
}
