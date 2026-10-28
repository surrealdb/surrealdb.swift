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

@Test
func injection_noneAndBytesAreWrittenInline() {
    // JSON would send NONE as NULL and bytes as base64 text.
    let missing = SurrealField<PlainModel, String?>("nickname") == nil
    #expect(missing.raw == "`nickname` = NONE")
    #expect(missing.bindings.isEmpty)
    let bytes = SurrealField<PlainModel, SurrealValue>("blob") == .bytes(Data([0xff]))
    #expect(bytes.raw == #"`blob` = encoding::base64::decode("/w==")"#)
    #expect(bytes.bindings.isEmpty)
}

@Test
func injection_explicitBindingsDontOverridePredicateOnes() {
    let predicate = SurrealPredicate(raw: "a = $x", bindings: ["x": .int(1)])
    let query = SurrealDSL.select(PlainModel.self, where: predicate, bindings: ["x": .int(2)])
    #expect(query.bindings["x"] == .int(2))
    let renamed = try! #require(query.bindings.first { $0.value == .int(1) }?.key)
    #expect(query.sql.contains("a = $\(renamed)"))
    // Same value: nothing to rename.
    let same = SurrealDSL.select(PlainModel.self, where: predicate, bindings: ["x": .int(1)])
    #expect(same.sql.contains("a = $x"))
    #expect(same.bindings == ["x": .int(1)])
}

@Test
func injection_renamingSkipsStringsAndComments() {
    let sql = "b = $value AND note = '$value' AND q = \"$value\" AND `$value` = 1 -- $value\nAND c = $value2 AND d = $value /* $value */"
    #expect(SurrealQL.renameParameter("value", to: "v9", in: sql)
        == "b = $v9 AND note = '$value' AND q = \"$value\" AND `$value` = 1 -- $value\nAND c = $value2 AND d = $v9 /* $value */")
    #expect(SurrealQL.renameParameter("x", to: "y", in: #"s = 'it\'s $x' AND $x"#) == #"s = 'it\'s $x' AND $y"#)
}

@Test
func injection_typedValuesInsideContainersAreInlined() {
    let date = Date(timeIntervalSince1970: 0)
    let nested = SurrealField<PlainModel, SurrealValue>("schedule") == .array([.datetime(date), .string("x")])
    #expect(nested.bindings.isEmpty)
    #expect(nested.raw == "`schedule` = [d\"1970-01-01T00:00:00.000Z\", \"x\"]")
    // Plain containers are still bound.
    let plain = SurrealField<PlainModel, SurrealValue>("tags") == .array([.string("a")])
    #expect(plain.bindings.count == 1)
}

@Test
func injection_renamingAvoidsNamesAlreadyInUse() {
    let lhs = SurrealPredicate(raw: "a = $x", bindings: ["x": .int(1)])
    // The name the last predicate got tells us what the counter hands out next.
    let last = try! #require((SurrealField<PlainModel, Int>("p") == 1).bindings.keys.first)
    let following = "_pv\(UInt64(last.dropFirst(3))! + 1)"
    // The right-hand side already uses the name the counter hands out next.
    let rhs = SurrealPredicate(raw: "b = $x AND c = $\(following)", bindings: ["x": .int(2), following: .int(3)])
    let combined = lhs && rhs
    #expect(combined.bindings[following] == .int(3))
    #expect(Set(combined.bindings.values) == Set<SurrealValue>([.int(1), .int(2), .int(3)]))
}

@Test
func injection_fieldPathsKeepArrayParts() {
    #expect(SurrealQL.escapeFieldPath("results[0].score") == "`results`[0].`score`")
    #expect(SurrealQL.escapeFieldPath("tags[*]") == "`tags`[*]")
    #expect(SurrealQL.escapeFieldPath("tags[$]") == "`tags`[$]")
    #expect(SurrealQL.escapeFieldPath("odd[x]") == "`odd[x]`")
    #expect(SurrealValue.double(.nan).sqlLiteral == "NaN")
}

@Test
func injection_transactionRenameLeavesStringLiteralsAlone() {
    let tx = SurrealTransaction()
    tx.append("CREATE a SET n = $x", bindings: ["x": .int(1)])
    tx.append("CREATE b SET n = $x, note = 'costs $x'", bindings: ["x": .int(2)])
    let (sql, bindings) = tx.build()
    #expect(sql.contains("note = 'costs $x'"))
    #expect(bindings.count == 2)
    #expect(!sql.contains("$x_tx1'"))
}
