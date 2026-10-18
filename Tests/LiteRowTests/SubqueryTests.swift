//
//  SubqueryTests.swift
//  LiteRowTests
//

import Testing

@testable import LiteRow

@Suite("Nested SELECT")
struct SubqueryTests {
    /// Groups of category 6: a plain subquery, a one-column projection plus its own filter.
    private func frigateGroups() -> QueryBuilder<Scalar<UInt32>, TypeGroup, ()> {
        TypeGroup.all()
            .filter { group in group.categoryID == UInt32(6) && group.name.like("Frigate%") }
            .select { group in group.id }
    }

    @Test("text: occurrence numbering runs through the whole query")
    func numbersOccurrencesAcrossScopes() {
        // A nested SELECT continues the outer numbering instead of restarting at zero. Otherwise `t0`
        // would mean two different tables in one text; the SQL stays valid (the inner name shadows the outer).
        let sql = TypeInfo.all()
            .filter { type in type.groupID.in(frigateGroups()) }
            .query().sql
        #expect(sql == #"""
            SELECT * FROM "main"."invTypes" AS t0 WHERE t0."groupID" IN (SELECT t1."groupID" FROM "main"."invGroups" AS t1 WHERE t1."categoryID" = ? AND t1."groupName" LIKE ?)
            """#)
    }

    @Test("a subquery with its own join gets its own occurrences")
    func numbersJoinedOccurrencesOfSubquery() {
        let inner = TypeGroup.all()
            .join(TypeInfo.self) { group, type in type.groupID == group.id }
            .select { group, _ in group.id }
        let sql = TypeInfo.all()
            .filter { type in type.groupID.in(inner) }
            .query().sql
        #expect(sql.contains(#"IN (SELECT t1."groupID" FROM "main"."invGroups" AS t1 JOIN "main"."invTypes" AS t2 ON t2."groupID" = t1."groupID")"#))
    }

    @Test("sibling subqueries do not share occurrence names")
    func numbersSiblingSubqueriesApart() {
        // Sibling subqueries are not nested, so SQL would let them reuse the same names, but one name
        // meaning two tables in one text is hard to read. Numbering therefore runs through the whole query.
        let groups = TypeGroup.all().select { group in group.id }
        let others = TypeGroup.all()
            .filter { group in group.categoryID == UInt32(7) }
            .select { group in group.id }
        let sql = TypeInfo.all()
            .filter { type in type.groupID.in(groups) }
            .filter { type in type.groupID.notIn(others) }
            .query().sql

        #expect(sql.contains(#"IN (SELECT t1."groupID" FROM "main"."invGroups" AS t1)"#))
        #expect(sql.contains(#"NOT IN (SELECT t2."groupID" FROM "main"."invGroups" AS t2"#))
    }

    @Test("NOT IN")
    func rendersNotIn() {
        let sql = TypeInfo.all()
            .filter { type in type.groupID.notIn(frigateGroups()) }
            .query().sql
        #expect(sql.contains(#"t0."groupID" NOT IN (SELECT"#))
    }

    @Test("subquery values land exactly where their `?` are in the text")
    func bindsSubqueryValuesInRenderOrder() {
        // A parameter's position is the position of its `?`, and a subquery inserts its values in the
        // middle. If they drifted the query would stay valid and silently return the wrong rows.
        let query = TypeInfo.all()
            .filter { type in type.id > UInt32(0) }
            .filter { type in type.groupID.in(frigateGroups()) }
            .filter { type in type.name.like("R%") }
            .limit(10)
            .query()

        #expect(query.bindings == [
            .integer(0),            // WHERE t0."typeID" > ?
            .integer(6),            // …IN (… WHERE t1."categoryID" = ?
            .text("Frigate%"),      // …          AND t1."groupName" LIKE ?)
            .text("R%"),            // AND t0."typeName" LIKE ?
            .integer(10),           // LIMIT ?
        ])
    }

    @Test("the text does not depend on the subquery values")
    func keepsStatementCacheKeyStable() {
        // The `StatementCache` key is the query text. A subquery must pass its values as parameters,
        // otherwise the cache would create a statement per value.
        func query(category: UInt32) -> SQLQuery<TypeInfo> {
            let groups = TypeGroup.all()
                .filter { group in group.categoryID == category }
                .select { group in group.id }
            return TypeInfo.all().filter { type in type.groupID.in(groups) }.query()
        }
        #expect(query(category: 6).sql == query(category: 7).sql)
        #expect(query(category: 6).bindings != query(category: 7).bindings)
    }

    @Test("selecting through IN (SELECT …)")
    func fetchesThroughSubquery() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all()
                .filter { type in type.groupID.in(frigateGroups()) }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Rifter", "Punisher"])
        withExtendedLifetime(fixture) {}
    }

    @Test("NOT IN (SELECT …) selects the complement")
    func fetchesThroughNotIn() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all()
                .filter { type in type.groupID.notIn(frigateGroups()) }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("a subquery in the projection and in ordering")
    func worksOutsideWhere() async throws {
        // The node is an ordinary expression, so it is not tied to `WHERE`. This also checks the order:
        // projection values come before `WHERE` values in the text.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let rows = try await database.read { reader in
            let query = TypeInfo.all()
                .select { type in (type.id, type.groupID.in(frigateGroups())) }
                .filter { type in type.id > UInt32(1) }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map { ($0.values.0, $0.values.1) }
        }

        #expect(rows.map(\.0) == [2, 3])
        #expect(rows.map(\.1) == [true, false])
        withExtendedLifetime(fixture) {}
    }
}

@Suite("Occurrence identity")
struct TableAliasIdentityTests {
    @Test("two identically built queries give the same text")
    func numbersAreLocalToRender() {
        // The query number comes from a global counter and does not reach the SQL: scope bases are
        // counted from zero at render time. Otherwise aliases would grow across the process
        // (`t0`, `t1`, `t2`, …) and `StatementCache` would get a new key for every same-shaped query.
        func build() -> String {
            TypeInfo.all()
                .join(TypeGroup.self) { type, group in type.groupID == group.id }
                .filter { _, group in group.categoryID == UInt32(6) }
                .query().sql
        }
        let first = build()
        for _ in 0..<10 {
            #expect(build() == first)
        }
        #expect(first.contains(#"AS t0"#))
        #expect(first.contains(#"AS t1"#))
        #expect(!first.contains(#"AS t2"#))
    }

    @Test("a subquery does not shift the numbering of the outer query")
    func outerNumberingIsIndependentOfSubquery() {
        let groups = TypeGroup.all().select { group in group.id }
        let withSubquery = TypeInfo.all()
            .filter { type in type.groupID.in(groups) }
            .query().sql
        #expect(withSubquery.hasPrefix(#"SELECT * FROM "main"."invTypes" AS t0"#))
    }
}

@Suite("Correlated subquery")
struct CorrelatedSubqueryTests {
    @Test("an outer query reference resolves to the outer table")
    func resolvesOuterReference() {
        // Without distinct scope bases `type` inside the subquery would have number 0 and silently
        // resolve to the subquery's table.
        let sql = TypeInfo.all()
            .filter { type in
                exists(
                    TypeGroup.all()
                        .filter { group in group.id == type.groupID && group.categoryID == UInt32(6) }
                        .select { group in group.id }
                )
            }
            .query().sql
        #expect(sql == #"""
            SELECT * FROM "main"."invTypes" AS t0 WHERE EXISTS (SELECT t1."groupID" FROM "main"."invGroups" AS t1 WHERE t1."groupID" = t0."groupID" AND t1."categoryID" = ?)
            """#)
    }

    @Test("EXISTS selects rows by relation, not by value")
    func fetchesThroughExists() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all()
                .filter { type in
                    exists(
                        TypeGroup.all()
                            .filter { group in group.id == type.groupID && group.name.like("Frigate%") }
                            .select { group in group.id }
                    )
                }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Rifter", "Punisher"])
        withExtendedLifetime(fixture) {}
    }

    @Test("NOT EXISTS selects the complement")
    func fetchesThroughNotExists() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all()
                .filter { type in
                    notExists(
                        TypeAttribute.all()
                            .filter { attribute in attribute.typeID == TypeID(rawValue: 1) }
                            .select { attribute in attribute.attributeID }
                    )
                }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        // The subquery is uncorrelated and non-empty, so `NOT EXISTS` is false for every row.
        #expect(names.isEmpty)
        withExtendedLifetime(fixture) {}
    }

    @Test("the same subquery inserted twice gets different occurrences")
    func embedsSameSubqueryTwice() {
        // Both insertions push the same scope with different bases onto the stack, and lookup goes
        // from inner to outer, so a reference inside the second insertion takes its base.
        let groups = TypeGroup.all().select { group in group.id }
        let sql = TypeInfo.all()
            .filter { type in type.groupID.in(groups) }
            .filter { type in type.groupID.notIn(groups) }
            .query().sql
        #expect(sql.contains(#"IN (SELECT t1."groupID" FROM "main"."invGroups" AS t1)"#))
        #expect(sql.contains(#"NOT IN (SELECT t2."groupID" FROM "main"."invGroups" AS t2)"#))
    }

    @Test("correlated IN")
    func correlatedIn() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all()
                .filter { type in
                    type.groupID.in(
                        TypeGroup.all()
                            .filter { group in group.categoryID == UInt32(6) && group.id == type.groupID }
                            .select { group in group.id }
                    )
                }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Rifter", "Punisher", "Raven"])
        withExtendedLifetime(fixture) {}
    }
}
