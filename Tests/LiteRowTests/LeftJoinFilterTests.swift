//
//  LeftJoinFilterTests.swift
//  LiteRowTests
//

import Testing

@testable import LiteRow

@Suite("NULL checks")
struct NullCheckTests {
    @Test("text: IS NULL and IS NOT NULL")
    func rendersNullChecks() {
        let joined = TypeInfo.all()
            .leftJoin(TypeGroup.self) { type, group in group.id == type.groupID }

        #expect(joined.filter { _, group in group.id.isNull() }.query().sql
                .hasSuffix(#"WHERE t1."groupID" IS NULL"#))
        #expect(joined.filter { _, group in group.id.isNotNull() }.query().sql
                .hasSuffix(#"WHERE t1."groupID" IS NOT NULL"#))
    }

    @Test("the check works on a non-optional column")
    func appliesToNonOptionalColumn() {
        // After a `LEFT JOIN` optionality belongs to the row, not the column, and `TypeGroup.id` stays
        // `UInt32`. Constraining `Base: Expression<Value?>` would make this predicate inexpressible,
        // and `== nil` would force declaring the join column optional, which lies about the schema.
        #expect(TypeGroup.columns.id.descriptor.isNullable == false)

        let sql = TypeInfo.all()
            .leftJoin(TypeGroup.self) { type, group in group.id == type.groupID }
            .filter { _, group in group.id.isNotNull() }
            .query().sql
        #expect(sql.contains(#"t1."groupID" IS NOT NULL"#))
    }

    @Test("OR inside one predicate gets parentheses")
    func parenthesizesOr() {
        // Predicates are joined with AND; without parentheses a filter appended after
        // `flag = ? OR pair IS NOT NULL` would be split on OR and the query would silently return wrong rows.
        let sql = TypeInfo.all()
            .leftJoin(TypeGroup.self) { type, group in group.id == type.groupID }
            .filter { type, group in type.groupID == UInt32(27) || group.id.isNotNull() }
            .filter { type, _ in type.id > UInt32(0) }
            .query().sql
        #expect(sql.hasSuffix(
            #"WHERE (t0."groupID" = ? OR t1."groupID" IS NOT NULL) AND t0."typeID" > ?"#
        ))
    }

    @Test("a join miss is selected by IS NULL, a hit by IS NOT NULL")
    func filtersByJoinMiss() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        // The `ON` condition deliberately does not match every row: Rifter and Punisher are frigates,
        // Raven is not, so it gets no pair.
        func query(miss: Bool) -> SQLQuery<Join<TypeInfo, TypeGroup?>> {
            let joined = TypeInfo.all()
                .leftJoin(TypeGroup.self) { type, group in
                    group.id == type.groupID && group.name.like("Frigate%")
                }
            return joined
                .filter { _, group in miss ? group.id.isNull() : group.id.isNotNull() }
                .order(by: { type, _ in type.id })
                .query()
        }

        let (missed, matched) = try await database.read { reader in
            (try reader.fetchAll(query(miss: true)).map(\.left.name),
             try reader.fetchAll(query(miss: false)).map(\.left.name))
        }

        #expect(missed == ["Raven"])
        #expect(matched == ["Rifter", "Punisher"])
        withExtendedLifetime(fixture) {}
    }

    @Test("optional constraint: no pair OR the pair matches")
    func expressesOptionalRestriction() async throws {
        // A row passes if it has no constraints at all or the constraint holds.
        // `groupID` plays the role of the "has constraints" flag here.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let joined = TypeInfo.all()
                .leftJoin(TypeGroup.self) { type, group in
                    group.id == type.groupID && group.name.like("Frigate%")
                }
            let query = joined
                .filter { type, group in
                    type.groupID == UInt32(27) || group.id.isNotNull()
                }
                .order(by: { type, _ in type.id })
                .query()
            return try reader.fetchAll(query).map(\.left.name)
        }

        #expect(names == ["Rifter", "Punisher", "Raven"])
        withExtendedLifetime(fixture) {}
    }
}

@Suite("Projection onto a table")
struct TableProjectionTests {
    @Test("text: columns of one occurrence in descriptor order")
    func rendersColumnsOfOneTable() {
        let sql = TypeInfo.all()
            .leftJoin(TypeIcon.self) { type, icon in icon.typeID == type.id }
            .select { type, _ in type }
            .query().sql
        #expect(sql == #"SELECT t0."typeID", t0."typeName", t0."groupID" FROM "main"."invTypes" AS t0 LEFT JOIN "main"."eveIcons" AS t1 ON t1."typeID" = t0."typeID""#)
    }

    @Test("the chosen occurrence is projected, not the source")
    func projectsSelectedOccurrence() {
        // Self-join: both sides are one table, told apart only by the alias. If the projection took
        // the schema or alias from the type rather than the passed reference, the failure would be silent:
        // columns of the wrong occurrence would arrive.
        let sql = TypeInfo.all()
            .join(TypeInfo.self) { lhs, rhs in lhs.groupID == rhs.groupID && lhs.id != rhs.id }
            .select { _, rhs in rhs }
            .query().sql
        #expect(sql.hasPrefix(#"SELECT t1."typeID", t1."typeName", t1."groupID" FROM"#))
    }

    @Test("Output is the table itself, join columns do not come along")
    func decodesProjectedTable() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let types: [TypeInfo] = try await database.read { reader in
            let joined = TypeInfo.all()
                .leftJoin(TypeGroup.self) { type, group in
                    group.id == type.groupID && group.name.like("Frigate%")
                }
            let query = joined
                .filter { _, group in group.id.isNull() }
                .select { type, _ in type }
                .query()
            return try reader.fetchAll(query)
        }

        // A missed `LEFT JOIN` no longer breaks decoding: its columns are not in the projection.
        #expect(types.map(\.name) == ["Raven"])
        #expect(types.first?.groupID == 27)
        withExtendedLifetime(fixture) {}
    }
}
