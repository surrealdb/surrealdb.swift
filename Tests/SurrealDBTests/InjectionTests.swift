import Foundation
import Testing
@testable import SurrealDB

private struct InjectionModel: SurrealModel {
    static let surrealTable = "we`ird\\table"
    let name: String
}

private struct PlainModel: SurrealModel {
    static let surrealTable = "person"
    let name: String
}

private let hostile = #"x\"; DELETE person; --\"#

@Test
func injection_predicateValuesAreBoundNotInterpolated() {
    let predicate = SurrealField<PlainModel, String>("name") == hostile
    #expect(!predicate.raw.contains("DELETE"))
    #expect(!predicate.raw.contains("\\"))
    #expect(predicate.bindings.count == 1)
    #expect(predicate.bindings.values.first == .string(hostile))

    let query = SurrealDSL.select(PlainModel.self, where: predicate)
    #expect(!query.sql.contains("DELETE"))
    #expect(query.bindings.values.contains(.string(hostile)))
}

@Test
func injection_combinedPredicatesKeepEveryBinding() {
    let name = SurrealField<PlainModel, String>("name")
    let age = SurrealField<PlainModel, Int>("age")
    let predicate = !(name == "a" || name == "b") && age > 3
    #expect(predicate.bindings.count == 3)
    #expect(Set(predicate.bindings.values) == [.string("a"), .string("b"), .int(3)])
    for key in predicate.bindings.keys {
        #expect(predicate.raw.contains("$\(key)"))
    }
}

@Test
func injection_tableAndFieldNamesAreEscaped() {
    let query = SurrealDSL.select(InjectionModel.self, where: SurrealField<InjectionModel, String>("na`me") == "x")
    #expect(query.sql.hasPrefix(#"SELECT * FROM `we\`ird\\table` WHERE `na\`me` = $_pv"#))

    let live = SurrealDSL.live(PlainModel.self, fetch: ["author.name"])
    #expect(live.sql == "LIVE SELECT * FROM `person` FETCH `author`.`name`;")
}

@Test
func injection_escapeHelpers() {
    #expect(SurrealQL.escapeIdent("value") == "`value`")
    #expect(SurrealQL.escapeIdent(#"a`b\c"#) == #"`a\`b\\c`"#)
    #expect(SurrealQL.quote(#"a"b\c"#) == #""a\"b\\c""#)
}

@Test
func injection_sqlLiteralEscapesBackslashes() {
    // A trailing backslash used to escape the closing quote.
    #expect(SurrealValue.string(#"x\"#).sqlLiteral == #""x\\""#)
    #expect(SurrealValue.string(hostile).sqlLiteral == #""x\\\"; DELETE person; --\\""#)
    #expect(SurrealValue.duration("1h; DELETE person").sqlLiteral == #"<duration>"1h; DELETE person""#)
    #expect(SurrealValue.duration("1h30m").sqlLiteral == "1h30m")
    #expect(SurrealValue.decimal("1; DELETE person").sqlLiteral == #"<decimal>"1; DELETE person""#)
    #expect(SurrealValue.decimal("-1.5").sqlLiteral == "-1.5dec")
    #expect(SurrealValue.object(["a b": .int(1)]).sqlLiteral == #"{"a b": 1}"#)
}

@Test
func injection_recordIDRenderingEscapes() {
    #expect(SurrealRecordID(table: "person", id: .string("alice")).rawValue == "person:alice")
    #expect(SurrealRecordID(table: "person", id: .string("123")).rawValue == "person:`123`")
    #expect(SurrealRecordID(table: "person", id: .string("a`; DELETE x")).rawValue == #"person:`a\`; DELETE x`"#)
    #expect(SurrealRecordID(table: "my table", id: .int(1)).rawValue == "`my table`:1")
}

@Test
func injection_combiningRenamesClashingBindings() {
    // Two hand-written predicates reusing `$value` with different values used
    // to send the left value for both.
    let x = SurrealPredicate(raw: "x = $value", bindings: ["value": .int(1)])
    let y = SurrealPredicate(raw: "y = $value OR z = $values", bindings: ["value": .int(2), "values": .int(3)])
    let both = x && y
    #expect(both.bindings["value"] == .int(1))
    #expect(both.bindings["values"] == .int(3))
    let renamed = both.bindings.first { $0.value == .int(2) }?.key
    #expect(renamed != nil && renamed != "value")
    #expect(both.raw == "(x = $value AND y = $\(renamed ?? "") OR z = $values)")

    // The same name bound to the same value is shared, not renamed.
    let same = x || SurrealPredicate(raw: "w = $value", bindings: ["value": .int(1)])
    #expect(same.raw == "(x = $value OR w = $value)")
    #expect(same.bindings == ["value": .int(1)])
}

@Test
func injection_typedPredicateValuesAreCast() {
    // The JSON wire format sends these as strings, so the comparison casts
    // them back; over CBOR the cast is a no-op.
    let date = SurrealField<PlainModel, Date>("at") == Date(timeIntervalSince1970: 0)
    #expect(date.raw.hasPrefix("`at` = <datetime>$_pv"))
    let id = SurrealField<PlainModel, SurrealRecordID>("owner") == SurrealRecordID(table: "person", id: .int(1))
    #expect(id.raw.hasPrefix("`owner` = <record>$_pv"))
    let uuid = SurrealField<PlainModel, UUID>("ref") == UUID()
    #expect(uuid.raw.hasPrefix("`ref` = <uuid>$_pv"))
    let plain = SurrealField<PlainModel, String>("name") == "x"
    #expect(plain.raw.hasPrefix("`name` = $_pv"))
}
