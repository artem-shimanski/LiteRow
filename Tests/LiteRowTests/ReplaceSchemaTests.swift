//
//  ReplaceSchemaTests.swift
//  LiteRowTests
//

import Foundation
import Testing
@testable import LiteRow

/// Replacing an attached file on a live database.
///
/// The use case is a language change: names live in a separate file, and switching must not
/// cost a new `Database`, i.e. the lost statement cache of `main`.
@Suite("Replacing an attached database")
struct ReplaceSchemaTests {
    /// The same `eveIcons` with different values, so you can tell which file a row came from.
    private static let englishSQL = """
        CREATE TABLE eveIcons (
            iconID INTEGER PRIMARY KEY,
            typeID INTEGER NOT NULL,
            iconFile TEXT NOT NULL
        );
        INSERT INTO eveIcons VALUES (100, 1, 'рифтер.png'), (101, 3, 'ворон.png');
        """

    private static let russianSQL = """
        CREATE TABLE eveIcons (
            iconID INTEGER PRIMARY KEY,
            typeID INTEGER NOT NULL,
            iconFile TEXT NOT NULL
        );
        INSERT INTO eveIcons VALUES (100, 1, 'рифтер.png'), (101, 3, 'ворон.png');
        """

    @MainActor
    @Test("replacement changes the data on both the main connection and the pool")
    func replaceSwapsData() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: Self.englishSQL)
        let russian = try MemoryDatabaseFixture(sql: Self.russianSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: english.name)]
        )

        let query = AuxIcon.all().order(by: { $0.id }).query()

        // Warm up both paths: the main connection (readSync) and pool connections (read),
        // each with its own statement cache, must see the new file.
        let before = try database.readSync { reader in try? reader.fetchAll(query).map(\.path) }
        #expect(before == ["рифтер.png", "ворон.png"])
        let beforeAsync = try await database.read { reader in try reader.fetchAll(query).map(\.path) }
        #expect(beforeAsync == ["рифтер.png", "ворон.png"])

        try await database.replace(.aux, with: .memory(name: russian.name))

        let after = try database.readSync { reader in try? reader.fetchAll(query).map(\.path) }
        #expect(after == ["рифтер.png", "ворон.png"])
        let afterAsync = try await database.read { reader in try reader.fetchAll(query).map(\.path) }
        #expect(afterAsync == ["рифтер.png", "ворон.png"])

        withExtendedLifetime((main, english, russian)) {}
    }

    @MainActor
    @Test("the statement cache survives replacement")
    func preparedStatementsSurviveReplace() async throws {
        // The point of the whole operation is not to drop a warmed-up cache. A statement on the replaced
        // schema stays cached and is re-prepared by itself after `DETACH`/`ATTACH`:
        // `sqlite3_prepare_v2` does this transparently on the first `step`.
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: Self.englishSQL)
        let russian = try MemoryDatabaseFixture(sql: Self.russianSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: english.name)]
        )

        // The same query text before and after: it is the cache key.
        let query = AuxIcon.all().filter { $0.id == 100 }.query()
        _ = try database.readSync { reader in try? reader.fetchOne(query)?.path }

        try await database.replace(.aux, with: .memory(name: russian.name))

        let path = try database.readSync { reader in try? reader.fetchOne(query)?.path }
        #expect(path == "рифтер.png")
        withExtendedLifetime((main, english, russian)) {}
    }

    @MainActor
    @Test("revision grows on every successful replacement")
    func revisionGrows() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: Self.englishSQL)
        let russian = try MemoryDatabaseFixture(sql: Self.russianSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: english.name)]
        )

        #expect(database.revision == 0)
        try await database.replace(.aux, with: .memory(name: russian.name))
        #expect(database.revision == 1)
        try await database.replace(.aux, with: .memory(name: english.name))
        #expect(database.revision == 2)
        withExtendedLifetime((main, english, russian)) {}
    }

    @MainActor
    @Test("a foreign build is rejected before the replacement, not after")
    func mismatchedStampIsRejectedBeforeDetach() async throws {
        // The check connection opens before the first `DETACH`, so a failed replacement
        // does not leave the database without a schema: the old file stays in place.
        let main = try MemoryDatabaseFixture(sql: "PRAGMA user_version = 7;\n" + TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: "PRAGMA user_version = 7;\n" + Self.englishSQL)
        let stale = try MemoryDatabaseFixture(sql: "PRAGMA user_version = 6;\n" + Self.russianSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: english.name)],
            options: Database.Options(schemaVersion: 7)
        )

        let query = AuxIcon.all().order(by: { $0.id }).query()

        var thrown: LiteRowError?
        do {
            try await database.replace(.aux, with: .memory(name: stale.name))
        }
        catch {
            thrown = error
        }

        guard case let .schemaMismatch(mismatch) = thrown else {
            Issue.record("expected schemaMismatch, got \(String(describing: thrown))")
            return
        }
        // The schema name is the one being replaced, not the check connection's `main`.
        #expect(mismatch.schema == "aux")
        #expect(mismatch.actual == 6)

        // The database stays usable on the old file.
        let paths = try await database.read { reader in try reader.fetchAll(query).map(\.path) }
        #expect(paths == ["рифтер.png", "ворон.png"])
        #expect(database.revision == 0)
        withExtendedLifetime((main, english, stale)) {}
    }

    @MainActor
    @Test("a schema can be attached by replacement if it was absent at open")
    func replaceCanAttachNewSchema() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: Self.englishSQL)

        let database = try Database(main: .memory(name: main.name), attached: [:])
        try await database.replace(.aux, with: .memory(name: english.name))

        let paths = try await database.read { reader in
            try reader.fetchAll(AuxIcon.all().order(by: { $0.id }).query()).map(\.path)
        }
        #expect(paths == ["рифтер.png", "ворон.png"])
        withExtendedLifetime((main, english)) {}
    }

    @MainActor
    @Test("replacement does not disturb parallel reads")
    func concurrentReadsSurviveReplace() async throws {
        // The barrier takes the whole pool limit, so readers wait for it instead of seeing
        // half the connections on the new file and half on the old.
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let english = try MemoryDatabaseFixture(sql: Self.englishSQL)
        let russian = try MemoryDatabaseFixture(sql: Self.russianSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: english.name)]
        )
        let query = AuxIcon.all().order(by: { $0.id }).query()

        async let readers: [Int] = withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try await database.read { reader in try reader.fetchAll(query).count }
                }
            }
            var counts: [Int] = []
            for try await value in group { counts.append(value) }
            return counts
        }

        try await database.replace(.aux, with: .memory(name: russian.name))

        let counts = try await readers
        #expect(counts.allSatisfy { $0 == 2 })
        withExtendedLifetime((main, english, russian)) {}
    }
}
