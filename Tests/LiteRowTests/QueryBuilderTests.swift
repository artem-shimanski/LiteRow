//
//  QueryBuilderTests.swift
//  LiteRowTests
//

import Testing

@testable import LiteRow

@Suite("Parameter binding")
struct ParameterBindingTests {
    @Test("each clause's parameter lands on the position of its `?`")
    func bindsEveryClauseInRenderOrder() {
        // Pins the clause order, not just that the SQL text and the values agree.
        let joined = TypeInfo.all()
            .join(TypeGroup.self) { type, group in
                group.id == type.groupID && group.categoryID == UInt32(6)
            }
        let query = joined
            .select { type, _ in (type.id, type.groupID + UInt32(100)) }
            .filter { type, _ in type.name.like("R%") }
            .group(by: { type, _ in type.groupID })
            .having { type, _ in type.id.count() > 0 }
            .order(by: { type, _ in type.name })
            .limit(5, offset: 2)
            .query()

        #expect(query.bindings == [
            .integer(100),      // projection
            .integer(6),        // ON
            .text("R%"),        // WHERE
            .integer(0),        // HAVING
            .integer(5),        // LIMIT
            .integer(2),        // OFFSET
        ])
    }

    @Test("a projection value does not steal the WHERE parameter")
    func projectionParametersAreBound() async throws {
        // Regression: binding skipped the projection, which comes first in the SQL, so a value there
        // shifted every later parameter and the query silently returned the wrong rows.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let rows = try await database.read { reader in
            let query = TypeInfo.all()
                .select { type in (type.id, type.groupID + 5) }
                .filter { type in type.id == 3 }
                .query()
            return try reader.fetchAll(query).map { ($0.values.0, $0.values.1) }
        }

        #expect(rows.count == 1)
        #expect(rows.first?.0 == 3)
        #expect(rows.first?.1 == 32)
        withExtendedLifetime(fixture) {}
    }
}
