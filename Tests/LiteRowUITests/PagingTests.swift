//
//  PagingTests.swift
//  LiteRowUITests
//

import Testing
import LiteRow
@testable import LiteRowUI

/// Paging needs no special support in the bridge: `LIMIT`/`OFFSET` are a property of the query,
/// and the caller hands the query to the wrapper. This checks not that the feature exists but that
/// it holds together: the offset goes out as a parameter, the binding order is not mixed up,
/// and pages share a prepared statement.
@Suite("Pages")
@MainActor
struct PagingTests {

    private func page(_ index: Int, size: Int = 2) -> SQLQuery<TestType> {
        TestType.all()
            .order(by: { $0.id })
            .limit(size, offset: index * size)
            .query()
    }

    @Test("pages with an offset share one statement")
    func pagesShareOneStatement() {
        let pages = (1...4).map { page($0) }

        // The offset is a parameter, not a constant in the text. If that breaks, every page gets its
        // own statement and infinite scrolling compiles SQL on every step: it works, just slowly and silently.
        #expect(Set(pages.map(\.sql)).count == 1)
        #expect(Set(pages.map(\.bindings)).count == 4)
    }

    @Test("a zero offset is a separate text, and that is not an error")
    func zeroOffsetIsItsOwnStatement() {
        // `makeSQL` does not write `OFFSET` when the offset is zero, so the first page gets its own
        // statement. Two for the whole list rather than N: a builder branch is not worth it, but it is
        // worth knowing.
        #expect(page(0).sql != page(1).sql)
        #expect(page(0).bindings.count == 1)
        #expect(page(1).bindings.count == 2)
    }

    @Test("pages do not overlap and cover the selection")
    func pagesCoverTheResult() throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name))
        let cache = QueryCache<[TestType]>()

        let first = cache.value(for: page(0), database: database, failure: .silent)
        let second = cache.value(for: page(1), database: database, failure: .silent)
        let third = cache.value(for: page(2), database: database, failure: .silent)

        #expect(first.map(\.name) == ["Rifter", "Punisher"])
        #expect(second.map(\.name) == ["Raven"])
        #expect(third.isEmpty)

        withExtendedLifetime(fixture) {}
    }

    @Test("filter and page parameters are not swapped")
    func filterAndPageBindingsKeepOrder() throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name))
        let cache = QueryCache<[TestType]>()

        // Three parameters in one query: `groupID`, `LIMIT` and `OFFSET`. The binding order is the render
        // order and can drift completely silently: the fetch would just return the wrong rows.
        let query = TestType.all()
            .filter { $0.groupID == UInt32(25) }
            .order(by: { $0.id })
            .limit(1, offset: 1)
            .query()

        #expect(query.bindings == [.integer(25), .integer(1), .integer(1)])

        let rows = cache.value(for: query, database: database, failure: .silent)
        #expect(rows.map(\.name) == ["Punisher"])

        withExtendedLifetime(fixture) {}
    }

    @Test("growing the limit is a different query, not an addition to the previous one")
    func growingLimitIsADifferentQuery() throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name))
        let cache = QueryCache<[TestType]>()

        let short = TestType.all().order(by: { $0.id }).limit(1).query()
        let long = TestType.all().order(by: { $0.id }).limit(3).query()

        #expect(cache.value(for: short, database: database, failure: .silent).count == 1)
        #expect(cache.value(for: long, database: database, failure: .silent).count == 3)

        // The price of the "show more" trick via a growing limit: the second fetch reads everything again,
        // including what is already shown. On an immutable local database this is usually cheaper than
        // page-stitching machinery, but for a large list it has to be counted this way.
        #expect(cache.fetchCount == 2)

        withExtendedLifetime(fixture) {}
    }
}
