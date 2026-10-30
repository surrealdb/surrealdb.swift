import Foundation
import Testing
@testable import SurrealDB

private struct CRUDPerson: SurrealModel, Codable, Sendable {
    static let surrealTable = "crud_person"

    let id: String?
    let name: String
    let age: Int

    init(id: String? = nil, name: String, age: Int) {
        self.id = id
        self.name = name
        self.age = age
    }
}

@Test
func queryDSL_buildsFullCRUDStatements() {
    let select = SurrealDSL.select(CRUDPerson.self, where: nil, limit: 10, start: 0)
    #expect(select.sql == "SELECT * FROM `crud_person` LIMIT 10 START 0;")

    let create = SurrealDSL.create(CRUDPerson.self, contentBinding: "content", bindings: ["content": .object(["name": .string("Ada")])])
    #expect(create.sql == "CREATE `crud_person` CONTENT $content;")
    #expect(create.bindings["content"] != nil)

    let update = SurrealDSL.update(CRUDPerson.self, where: SurrealPredicate(raw: "age < 30"), contentBinding: "payload")
    #expect(update.sql == "UPDATE `crud_person` CONTENT $payload WHERE age < 30;")

    let upsert = SurrealDSL.upsert(CRUDPerson.self, where: SurrealPredicate(raw: "name = \"Ada\""), contentBinding: "payload")
    #expect(upsert.sql == "UPSERT `crud_person` CONTENT $payload WHERE name = \"Ada\";")

    let delete = SurrealDSL.delete(CRUDPerson.self, where: SurrealPredicate(raw: "age >= 18"))
    #expect(delete.sql == "DELETE `crud_person` WHERE age >= 18;")
}

@Test
func queryDSL_supportsFunctionQueries() {
    let functionQuery = SurrealQuery<SurrealValue>(sql: "RETURN fn::sdk::echo('hello');")
    #expect(functionQuery.sql.contains("fn::sdk::echo"))
}
