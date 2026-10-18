//
//  SectionsTests.swift
//  LiteRowUITests
//

import Testing
import LiteRow
@testable import LiteRowUI

@Suite("Sections")
@MainActor
struct SectionsTests {

    private func makeDatabase() throws -> (Database, MemoryDatabaseFixture) {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        return (try Database(main: .memory(name: fixture.name)), fixture)
    }

    private func makeQuery() -> SectionedQuery<GroupSection, TestType> {
        SectionedQuery(
            sections: SQLQuery<GroupSection>(#"SELECT DISTINCT "groupID" FROM "invTypes" ORDER BY "groupID""#),
            rows: { section in
                TestType.all()
                    .filter { $0.groupID == section.groupID }
                    .order(by: { $0.id })
                    .query()
            }
        )
    }

    @Test("all sections share one statement")
    func rowQueriesShareOneStatement() {
        let query = makeQuery()
        let sections = [GroupSection(groupID: 25), GroupSection(groupID: 27), GroupSection(groupID: 1)]
        let queries = sections.compactMap(query.rows)

        // The invariant that makes the two-query scheme worthwhile: the section key goes out as a
        // parameter, so `1 + N` fetches are one prepared statement and N bindings, not N SQL compilations.
        // Compiling the key into the text loses the statement cache unnoticed: it works, just slowly.
        #expect(Set(queries.map(\.sql)).count == 1)
        // And the other half: the values must differ, otherwise the key never reached the query.
        #expect(Set(queries.map(\.bindings)).count == 3)
    }

    @Test("rows are read only when a section is accessed")
    func rowsAreLoadedOnDemand() throws {
        let (database, fixture) = try makeDatabase()
        let cache = SectionsCache<GroupSection, TestType>()

        let result = cache.result(for: makeQuery(), database: database, failure: .silent)

        #expect(result.sections.map(\.groupID) == [25, 27])
        // Headers only: the rows of no section have been touched yet.
        #expect(cache.fetchCount == 1)

        #expect(result[GroupSection(groupID: 25)].map(\.name) == ["Rifter", "Punisher"])
        #expect(cache.fetchCount == 2)

        // A repeated access to the same section goes to the cache.
        #expect(result[GroupSection(groupID: 25)].count == 2)
        #expect(cache.fetchCount == 2)

        #expect(result[GroupSection(groupID: 27)].map(\.name) == ["Raven"])
        #expect(cache.fetchCount == 3)

        withExtendedLifetime(fixture) {}
    }

    @Test("changing the sections query resets the rows")
    func changingSectionsQueryDropsRows() throws {
        let (database, fixture) = try makeDatabase()
        let cache = SectionsCache<GroupSection, TestType>()

        let first = cache.result(for: makeQuery(), database: database, failure: .silent)
        _ = first[GroupSection(groupID: 25)]
        #expect(cache.fetchCount == 2)

        var narrowed = makeQuery()
        narrowed.sections = SQLQuery<GroupSection>(
            #"SELECT DISTINCT "groupID" FROM "invTypes" WHERE "groupID" = 25"#
        )
        let second = cache.result(for: narrowed, database: database, failure: .silent)

        #expect(second.sections.map(\.groupID) == [25])
        #expect(cache.fetchCount == 3)
        // The rows are read again: the earlier set may have belonged to a different filter.
        _ = second[GroupSection(groupID: 25)]
        #expect(cache.fetchCount == 4)

        withExtendedLifetime(fixture) {}
    }

    @Test("no sections query gives an empty result")
    func missingSectionsQuery() throws {
        let (database, fixture) = try makeDatabase()
        let cache = SectionsCache<GroupSection, TestType>()

        var query = makeQuery()
        query.sections = nil
        let result = cache.result(for: query, database: database, failure: .silent)

        #expect(result.isEmpty)
        #expect(cache.fetchCount == 0)

        withExtendedLifetime(fixture) {}
    }
}
