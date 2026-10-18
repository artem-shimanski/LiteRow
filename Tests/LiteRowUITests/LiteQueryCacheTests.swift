//
//  LiteQueryCacheTests.swift
//  LiteRowUITests
//

import Testing
import LiteRow
@testable import LiteRowUI

/// This tests memoization, not SwiftUI: the wrapper is a thin layer over the cache,
/// and everything that can break in it breaks here.
@Suite("Query cache")
@MainActor
struct LiteQueryCacheTests {

    private func makeDatabase() throws -> (Database, MemoryDatabaseFixture) {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        return (try Database(main: .memory(name: fixture.name)), fixture)
    }

    private var allTypes: SQLQuery<TestType> {
        TestType.all().order(by: { $0.id }).query()
    }

    @Test("the same query a second time does not hit the database")
    func memoizesEqualQuery() throws {
        let (database, fixture) = try makeDatabase()
        let cache = QueryCache<[TestType]>()

        let first = cache.value(for: allTypes, database: database, failure: .silent)
        let second = cache.value(for: allTypes, database: database, failure: .silent)

        #expect(first.map(\.name) == ["Rifter", "Punisher", "Raven"])
        #expect(second.map(\.name) == first.map(\.name))
        // The queries are built by two separate builder calls, so equality here is structural,
        // not by reference. If it breaks, the cache would silently miss on every frame.
        #expect(cache.fetchCount == 1)

        withExtendedLifetime(fixture) {}
    }

    @Test("a different parameter is a different query, a new fetch")
    func refetchesOnChangedBinding() throws {
        let (database, fixture) = try makeDatabase()
        let cache = QueryCache<[TestType]>()

        func query(groupID: UInt32) -> SQLQuery<TestType> {
            TestType.all().filter { $0.groupID == groupID }.order(by: { $0.id }).query()
        }

        let frigates = cache.value(for: query(groupID: 25), database: database, failure: .silent)
        let battleships = cache.value(for: query(groupID: 27), database: database, failure: .silent)

        #expect(frigates.map(\.name) == ["Rifter", "Punisher"])
        #expect(battleships.map(\.name) == ["Raven"])
        #expect(cache.fetchCount == 2)

        // And back: returning to the earlier parameter is a fetch again, the cache remembers only
        // the last query. More is not needed: the wrapper has exactly one at any moment.
        _ = cache.value(for: query(groupID: 25), database: database, failure: .silent)
        #expect(cache.fetchCount == 3)

        withExtendedLifetime(fixture) {}
    }

    @Test("no query is neither an error nor a fetch")
    func missingQueryIsNotAnError() throws {
        let (database, fixture) = try makeDatabase()
        let cache = QueryCache<[TestType]>()
        let log = ErrorLog()

        let value = cache.value(for: nil, database: database, failure: .init { log.append($0) })

        #expect(value.isEmpty)
        #expect(cache.fetchCount == 0)
        #expect(log.count == 0)

        withExtendedLifetime(fixture) {}
    }

    @Test("a missing database is reported exactly once")
    func missingDatabaseReportedOnce() {
        let cache = QueryCache<[TestType]>()
        let log = ErrorLog()
        let failure = LiteQueryFailure { log.append($0) }

        _ = cache.value(for: allTypes, database: nil, failure: failure)
        _ = cache.value(for: allTypes, database: nil, failure: failure)

        #expect(log.count == 1)
        #expect(log.errors.first as? LiteQueryError == .databaseMissing)
    }

    @Test("a failed query is not repeated on every frame")
    func failedQueryIsNotRetried() throws {
        let (database, fixture) = try makeDatabase()
        let cache = QueryCache<[TestType]>()
        let log = ErrorLog()
        let failure = LiteQueryFailure { log.append($0) }
        let broken = SQLQuery<TestType>("SELECT * FROM there_is_no_such_table")

        let first = cache.value(for: broken, database: database, failure: failure)
        let second = cache.value(for: broken, database: database, failure: failure)

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        // Key point: a failure is remembered too. Otherwise one broken query would trip the assert
        // as many times as SwiftUI re-evaluates `body`.
        #expect(cache.fetchCount == 1)
        #expect(log.count == 1)

        withExtendedLifetime(fixture) {}
    }

    @Test("a single value is read through fetchOne")
    func fetchesOptional() throws {
        let (database, fixture) = try makeDatabase()
        let cache = QueryCache<TestType?>()

        let query = TestType.all().filter { $0.id == UInt32(3) }.limit(1).query()
        let value = cache.value(for: query, database: database, failure: .silent)

        #expect(value?.name == "Raven")
        #expect(cache.fetchCount == 1)

        withExtendedLifetime(fixture) {}
    }
}

extension DatabaseFile {
    static let locale = DatabaseFile(schemaName: "loc")
}

/// Names in a separate file: what gets replaced when the language changes.
@Table("names", schema: .locale)
struct LocalizedName {
    @PrimaryKey @Column("typeID") var id: UInt32
    @Column("text") var text: String
}

/// Memoization against replacing an attached file.
///
/// The cache relies on the database being immutable, and `replace` is the one exception:
/// same query, different file. Without `revision` in the key the screen would stay on the old language
/// until the filter changed.
@Suite("Cache and file replacement")
@MainActor
struct LiteQueryRevisionTests {
    private static let englishSQL = """
        CREATE TABLE names (typeID INTEGER PRIMARY KEY, text TEXT NOT NULL);
        INSERT INTO names VALUES (1, 'Рифтер'), (3, 'Ворон');
        """

    private static let russianSQL = """
        CREATE TABLE names (typeID INTEGER PRIMARY KEY, text TEXT NOT NULL);
        INSERT INTO names VALUES (1, 'Рифтер'), (3, 'Ворон');
        """

    @Test("after a file replacement the same query is fetched again")
    func refetchesAfterReplace() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: Self.englishSQL)
        let russian = try MemoryDatabaseFixture(sql: Self.russianSQL)
        let database = try Database(
            main: .memory(name: main.name),
            attached: [.locale: .memory(name: english.name)]
        )

        let cache = QueryCache<[LocalizedName]>()
        let query = LocalizedName.all().order(by: { $0.id }).query()

        #expect(cache.value(for: query, database: database, failure: .silent).map(\.text)
            == ["Рифтер", "Ворон"])
        #expect(cache.fetchCount == 1)

        try await database.replace(.locale, with: .memory(name: russian.name))

        #expect(cache.value(for: query, database: database, failure: .silent).map(\.text)
            == ["Рифтер", "Ворон"])
        #expect(cache.fetchCount == 2)

        withExtendedLifetime((main, english, russian)) {}
    }
}
