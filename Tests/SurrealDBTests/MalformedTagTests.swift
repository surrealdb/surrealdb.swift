import Foundation
import PotentCBOR
import Testing
@testable import SurrealDB

private func decode(_ cbor: CBOR) throws -> SurrealValue {
    try CBORSurrealCodec.fromCBOR(cbor)
}

@Test
func malformedTags_invalidStringUUIDThrowsInsteadOfRandom() throws {
    let tag = CBORSurrealCodec.tagStringUUID
    // This used to decode to a brand-new random UUID.
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .utf8String("not-a-uuid"))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(tag, .unsignedInt(1))) }

    let uuid = UUID()
    #expect(try decode(.tagged(tag, .utf8String(uuid.uuidString.lowercased()))) == .uuid(uuid))
}

@Test
func malformedTags_otherTagsThrowInsteadOfInventingValues() {
    #expect(throws: SurrealError.self) { try decode(.tagged(.uuid, .byteString(Data([1, 2, 3])))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagTable, .unsignedInt(1))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagRecordID, .unsignedInt(1))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagStringDecimal, .utf8String("1; x"))) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagRange, .null)) }
    #expect(throws: SurrealError.self) { try decode(.tagged(CBORSurrealCodec.tagSet, .null)) }
}

@Test
func malformedTags_surfaceThroughTheEnvelope() throws {
    // A malformed value inside a result used to read as a missing result.
    var map = CBOR.Map()
    map[.utf8String("id")] = .utf8String("1")
    map[.utf8String("result")] = .tagged(CBORSurrealCodec.tagStringUUID, .utf8String("nope"))
    let data = try CBORSerialization.data(from: .map(map))
    #expect(throws: SurrealError.self) { try CBORSurrealCodec.decodeRPCEnvelope(data) }
}
