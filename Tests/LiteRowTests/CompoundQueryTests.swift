//
//  CompoundQueryTests.swift
//  LiteRowTests
//

import Testing

@testable import LiteRow

@Suite("Compound SELECT text")
struct CompoundQuerySQLTests {
    @Test("two queries are joined by an operator, occurrences are numbered across operands")
    func rendersOperatorBetweenOperands() {
        // Numbering runs through for the same reason as with subqueries: one counter hands out scope
        // bases for the whole render. With equal numbers one name would mean two tables.
        let sql = TypeInfo.all().select { type in type.name }
            .unionAll(TypeGroup.all().select { group in group.name })
            .makeSQL()

        #expect(sql == #"""
            SELECT t0."typeName" FROM "main"."invTypes" AS t0 UNION ALL SELECT t1."groupName" FROM "main"."invGroups" AS t1
            """#)
    }

    @Test("each operator is written with its own keyword")
    func rendersEveryOperator() {
        let left = TypeInfo.all().select { type in type.id }
        let right = TypeGroup.all().select { group in group.id }

        #expect(left.union(right).makeSQL().contains(" UNION SELECT "))
        #expect(left.unionAll(right).makeSQL().contains(" UNION ALL SELECT "))
        #expect(left.intersect(right).makeSQL().contains(" INTERSECT SELECT "))
        #expect(left.except(right).makeSQL().contains(" EXCEPT SELECT "))
    }

    @Test("an operand without ORDER BY and LIMIT is written without a wrapper")
    func plainOperandIsNotWrapped() {
        let sql = TypeInfo.all().filter { type in type.groupID == UInt32(25) }
            .union(TypeInfo.all().filter { type in type.groupID == UInt32(27) })
            .makeSQL()

        #expect(!sql.contains("SELECT * FROM ("))
    }

    @Test("an operand with its own LIMIT is wrapped in a subquery")
    func limitedOperandIsWrapped() {
        // SQLite rejects `ORDER BY`/`LIMIT` inside an operand at parse time ("LIMIT clause should
        // come after UNION not before"). The `SELECT * FROM (…)` wrapper puts them back in a legal
        // position without changing the column count or order.
        let sql = TypeInfo.all().order(by: { type in type.name }).limit(25)
            .union(TypeInfo.all().filter { type in type.groupID == UInt32(27) })
            .makeSQL()

        #expect(sql == #"""
            SELECT * FROM (SELECT * FROM "main"."invTypes" AS t0 ORDER BY t0."typeName" ASC LIMIT ?) UNION SELECT * FROM "main"."invTypes" AS t1 WHERE t1."groupID" = ?
            """#)
    }

    @Test("compound ORDER BY is a result column number")
    func compoundOrderIsPositional() {
        // This `ORDER BY` cannot be an expression: it applies to the whole compound, and operand
        // columns (`t0."typeName"`) do not resolve in that position.
        let sql = TypeInfo.all().select { type in type.name }
            .union(TypeGroup.all().select { group in group.name })
            .order(byColumn: 1, .descending)
            .limit(10, offset: 5)
            .makeSQL()

        #expect(sql.hasSuffix(" ORDER BY 1 DESC LIMIT ? OFFSET ?"))
    }

    @Test("order(by:) computes the column number from the model")
    func compoundOrderFromColumn() {
        // `typeName` is the second column of `invTypes`, so the second column of the whole-table
        // projection; SQL numbering starts at one.
        let sql = TypeInfo.all()
            .union(TypeInfo.all().filter { type in type.groupID == UInt32(27) })
            .order(by: \.name)
            .makeSQL()

        #expect(sql.hasSuffix(" ORDER BY 2 ASC"))
    }

    @Test("a union chain stays flat")
    func chainedUnionStaysFlat() {
        let sql = TypeInfo.all().select { type in type.id }
            .union(TypeInfo.all().select { type in type.groupID })
            .union(TypeGroup.all().select { group in group.id })
            .makeSQL()

        #expect(sql.components(separatedBy: " UNION ").count == 3)
        #expect(!sql.contains("SELECT * FROM ("))
    }

    @Test("a compound inside a compound goes into a subquery")
    func nestedCompoundIsWrapped() {
        // SQL has no parentheses around an operand, so grouping is expressed only by a subquery.
        // Without it the operators would be flattened and applied left to right, meaning something else.
        let inner = TypeInfo.all().select { type in type.id }
            .union(TypeInfo.all().select { type in type.groupID })
        let sql = TypeGroup.all().select { group in group.id }
            .except(inner)
            .makeSQL()

        #expect(sql.contains(" EXCEPT SELECT * FROM (SELECT "))
    }

    @Test("parameters are collected in render order")
    func bindsInRenderOrder() {
        // Binding order is the order of `?` in the text; in a compound it runs through the operands
        // left to right, and the compound's own `LIMIT` comes last.
        let query = TypeInfo.all()
            .filter { type in type.groupID == UInt32(25) }
            .limit(3)
            .union(TypeInfo.all().filter { type in type.groupID == UInt32(27) })
            .limit(10, offset: 2)
            .query()

        #expect(query.bindings == [
            .integer(25),   // WHERE of the first operand
            .integer(3),    // LIMIT of the first operand
            .integer(27),   // WHERE of the second operand
            .integer(10),   // LIMIT of the compound
            .integer(2),    // OFFSET of the compound
        ])
    }

    @Test("the text does not depend on how many queries were built before")
    func textIsStableAcrossQueries() {
        // The same requirement as for a plain query: the text is the `StatementCache` key,
        // and `QueryID` must not get into it.
        func make() -> String {
            TypeInfo.all().select { type in type.name }
                .union(TypeGroup.all().select { group in group.name })
                .makeSQL()
        }
        let first = make()
        _ = TypeInfo.all().join(TypeGroup.self) { type, group in type.groupID == group.id }
        #expect(make() == first)
    }

    @Test("a compound works on the right of IN")
    func compoundAsSubquery() {
        let groups = TypeGroup.all().filter { group in group.categoryID == UInt32(6) }
            .select { group in group.id }
            .union(TypeGroup.all().filter { group in group.id == UInt32(27) }
                .select { group in group.id })

        let sql = TypeInfo.all()
            .filter { type in type.groupID.in(groups) }
            .makeSQL()

        #expect(sql.contains(#"t0."groupID" IN (SELECT t1."groupID" FROM "main"."invGroups" AS t1 WHERE"#))
        #expect(sql.contains(" UNION SELECT t2."))
    }
}

@Suite("Compound SELECT execution")
struct CompoundQueryExecutionTests {
    @Test("UNION merges the results of two filters")
    func unionMergesRows() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all().filter { type in type.groupID == UInt32(25) }
                .union(TypeInfo.all().filter { type in type.id == UInt32(3) })
                .order(by: \.name)
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Punisher", "Raven", "Rifter"])
        withExtendedLifetime(fixture) {}
    }

    @Test("UNION removes duplicates, UNION ALL keeps them")
    func unionDeduplicates() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let (deduplicated, all) = try await database.read { reader in
            let operand = TypeInfo.all().filter { type in type.groupID == UInt32(25) }
            let unique = try reader.fetchAll(
                operand.union(TypeInfo.all().filter { type in type.groupID == UInt32(25) }).query()
            )
            let everything = try reader.fetchAll(
                operand.unionAll(TypeInfo.all().filter { type in type.groupID == UInt32(25) }).query()
            )
            return (unique.count, everything.count)
        }

        #expect(deduplicated == 2)
        #expect(all == 4)
        withExtendedLifetime(fixture) {}
    }

    @Test("rows of two different tables are combined by a scalar projection")
    func unionOfDifferentTables() async throws {
        // This is what the compound exists for: the operands have different sources but one `Output`.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all().select { type in type.name }
                .union(TypeGroup.all().select { group in group.name })
                .order(byColumn: 1)
                .query()
            return try reader.fetchAll(query).map(\.value)
        }

        #expect(names == ["Battleship", "Frigate", "Punisher", "Raven", "Rifter"])
        withExtendedLifetime(fixture) {}
    }

    @Test("an operand LIMIT limits the operand, not the union")
    func operandLimitIsPerOperand() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let byName = TypeInfo.all().filter { type in type.groupID == UInt32(25) }
                .order(by: { type in type.name })
                .limit(1)
            let byID = TypeInfo.all().filter { type in type.groupID == UInt32(27) }
            let query = byName.unionAll(byID).order(by: \.name).query()
            return try reader.fetchAll(query).map(\.name)
        }

        // One row came from group 25 (Rifter, Punisher): the first by name.
        #expect(names == ["Punisher", "Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("INTERSECT and EXCEPT compute what they do in SQL")
    func intersectAndExcept() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let (common, difference) = try await database.read { reader in
            let group25 = TypeInfo.all().filter { type in type.groupID == UInt32(25) }
            let firstTwo = TypeInfo.all().filter { type in type.id < UInt32(3) }
            let intersection = try reader.fetchAll(group25.intersect(firstTwo).query()).map(\.name)
            let subtracted = try reader.fetchAll(
                TypeInfo.all().except(group25).order(by: \.name).query()
            ).map(\.name)
            return (intersection.sorted(), subtracted)
        }

        #expect(common == ["Punisher", "Rifter"])
        #expect(difference == ["Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("the compound LIMIT cuts the already merged result")
    func compoundLimit() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all().filter { type in type.groupID == UInt32(25) }
                .union(TypeInfo.all().filter { type in type.id == UInt32(3) })
                .order(by: \.name)
                .limit(2, offset: 1)
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Raven", "Rifter"])
        withExtendedLifetime(fixture) {}
    }
}

@Suite("Search across two language indexes")
struct CompoundSearchTests {
    /// Two fts5 tables over one `invTypes`: English names come from the table itself
    /// (`content=`), the second language is a separate copy.
    static let sql = TestSchema.sql + """

        CREATE VIRTUAL TABLE invTypes_fts USING fts5(typeName, content='invTypes', content_rowid='typeID');
        INSERT INTO invTypes_fts(invTypes_fts) VALUES('rebuild');

        CREATE VIRTUAL TABLE invTypes_fts_ru USING fts5(typeName);
        INSERT INTO invTypes_fts_ru(rowid, typeName) VALUES
            (1, 'Рифтер Rapier'), (2, 'Каратель'), (3, 'Ворон Raven');
        """

    @Test("results of two indexes are merged, a match shared by both arrives once")
    func searchesBothLanguages() async throws {
        // `Raven` is in the English index and in the second-language text of the third row.
        // `UNION` must reduce this to one row: a duplicate is a match on all projection columns,
        // and the projection is reduced to `invTypes` itself.
        let fixture = try MemoryDatabaseFixture(sql: Self.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            guard let query = Examples.search("Raven", bothLanguages: true) else { return [String]() }
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("a row found only in the second-language index is in the results too")
    func findsRussianOnlyMatch() async throws {
        let fixture = try MemoryDatabaseFixture(sql: Self.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            guard let query = Examples.search("Рифтер", bothLanguages: true) else { return [String]() }
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Rifter"])
        withExtendedLifetime(fixture) {}
    }

    @Test("results of both indexes are merged into one list")
    func mergesMatchesFromBothIndexes() async throws {
        let fixture = try MemoryDatabaseFixture(sql: Self.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            // With prefix "Ra" the English index finds `Raven` and the second-language one finds `Rapier`
            // in the text of `Rifter`. The rows differ, so both must be in the results.
            guard let query = Examples.search("Ra", bothLanguages: true) else {
                return [String]()
            }
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Raven", "Rifter"])
        withExtendedLifetime(fixture) {}
    }
}
