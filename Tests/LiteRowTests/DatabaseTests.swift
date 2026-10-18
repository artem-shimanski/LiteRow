//
//  DatabaseTests.swift
//  LiteRowTests
//

import Foundation
import Testing
// `@_spi(Build)`: the test checks identifier escaping, which is exposed to LiteRowBuild.
@_spi(Build) @testable import LiteRow

@Suite("Source URIs")
struct SourceURITests {
    @Test("an in-memory database is addressed through memdb, not a shared cache")
    func memoryURI() {
        // The leading `/` is required: without it memdb gives every connection a private database.
        #expect(Database.Source.memory(name: "cache").uri == "file:/cache?vfs=memdb&mode=ro")
    }

    @Test("an in-memory database name is escaped as a single path segment")
    func memoryURIEscaping() {
        // `?` would end the URI at the parameter boundary, `/` would change the name the VFS sees.
        #expect(Database.Source.memory(name: "a b?c/d").uri == "file:/a%20b%3Fc%2Fd?vfs=memdb&mode=ro")
    }

    @Test("a file is opened read-only")
    func fileURI() {
        let url = URL(filePath: "/tmp/lite row.sqlite")
        #expect(Database.Source.file(url).uri == "file:/tmp/lite%20row.sqlite?immutable=1&mode=ro")
    }

    @Test("the mode parameter is set exactly once")
    func modeAppearsOnce() {
        // A repeated `mode=` is not ignored: the last one overrides the earlier one, read-only flag
        // included, so a duplicate silently loses the mode.
        for source in [Database.Source.memory(name: "x"), .file(URL(filePath: "/tmp/x.sqlite"))] {
            #expect(source.uri.components(separatedBy: "mode=").count == 2, "\(source.uri)")
        }
    }
}

@Suite("Opening a database")
struct DatabaseOpeningTests {
    @Test("a populated in-memory database is readable")
    func opensPrePopulatedMemoryDatabase() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            try reader.fetchAll(TypeInfo.all().order(by: { $0.id }).query()).map(\.name)
        }

        #expect(names == ["Rifter", "Punisher", "Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("a file database is readable")
    func opensFileDatabase() async throws {
        let fixture = try FileDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(url: fixture.url)

        let count = try await database.read { reader in
            try reader.fetchOne(TypeInfo.all().count().query())?.value
        }

        #expect(count == 3)
        withExtendedLifetime(fixture) {}
    }

    @Test("a missing file gives cannotOpenDatabase instead of crashing")
    func missingFileFails() throws {
        let url = URL(filePath: "/tmp/literow-missing-\(UUID().uuidString).sqlite")

        // Regression for a use-after-free: the error text was read from an already closed handle.
        #expect(throws: LiteRowError.self) {
            _ = try Database(url: url)
        }
    }

    @Test("open_v2 flags are correct: the connection opens at all")
    func openSucceedsWithReadOnlyFlag() throws {
        // Without SQLITE_OPEN_READONLY in the flags sqlite3_open_v2 rejects the call with SQLITE_MISUSE
        // before parsing the URI, so no database would open at all.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let configuration = Database.Configuration(
            main: .memory(name: fixture.name),
            attached: [:],
            options: .default
        )
        #expect(throws: Never.self) {
            _ = try Connection(configuration)
        }
        withExtendedLifetime(fixture) {}
    }

    @Test("a name nobody populated gives an empty database, not an error")
    func unpopulatedMemoryNameYieldsEmptyDatabase() async throws {
        // A documented trap: memdb silently creates an empty database, so the "fill first, then open"
        // order cannot be enforced on the user's behalf.
        let database = try Database(main: .memory(name: "literow-empty-\(UUID().uuidString)"), attached: [:])

        await #expect(throws: LiteRowError.self) {
            try await database.read { reader in
                try reader.fetchAll(TypeInfo.all().query())
            }
        }
    }

    @Test("a write is rejected")
    func rejectsWrites() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        await #expect(throws: LiteRowError.self) {
            try await database.read { reader in
                try reader.fetchOne(
                    SQLQuery<Scalar<Int>>("INSERT INTO invTypes VALUES (99, 'Nope', 25)")
                )
            }
        }
        withExtendedLifetime(fixture) {}
    }

    @Test("readSync reads through the main connection")
    @MainActor
    func readSyncUsesMainConnection() throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        // `readSync` takes a non-throwing closure, so the error has to be swallowed inside.
        let count = try database.readSync { reader in
            try? reader.fetchOne(TypeInfo.all().count().query())?.value
        }

        #expect(count == 3)
        withExtendedLifetime(fixture) {}
    }
}

@Suite("Connection pool")
struct ConnectionPoolTests {
    @Test("all pool connections see the same in-memory database")
    func everyConnectionSeesTheSameData() async throws {
        // The main regression. With a non-shared connection (or `cache=shared` without the leading `/`
        // on memdb) the second and later connections get their own empty database, and some queries
        // silently return zero rows.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    try await database.read { reader in
                        try reader.fetchAll(TypeInfo.all().query()).count
                    }
                }
            }
            var result: [Int] = []
            for try await value in group {
                result.append(value)
            }
            return result
        }

        #expect(counts.count == 64)
        #expect(counts.allSatisfy { $0 == 3 })
        withExtendedLifetime(fixture) {}
    }

    @Test("the pool hands out connections for any core count")
    func poolAlwaysOpensAtLeastOneConnection() async throws {
        // `min(4, activeProcessorCount - 1)` gave zero on a single core: the limit was exhausted
        // from the start and the first query waited forever.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let configuration = Database.Configuration(
            main: .memory(name: fixture.name),
            attached: [:],
            options: .default
        )
        let pool = ConnectionPool(configuration: configuration, maxConnections: 0)

        let count = try await pool.withConnection { connection in
            try Reader(connection: connection).fetchAll(TypeInfo.all().query()).count
        }

        #expect(count == 3)
        withExtendedLifetime(fixture) {}
    }

    @Test("connections are reused, not leaked")
    func connectionsAreReused() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        for _ in 0 ..< 200 {
            let count = try await database.read { reader in
                try reader.fetchAll(TypeInfo.all().query()).count
            }
            #expect(count == 3)
        }
        withExtendedLifetime(fixture) {}
    }
}

@Suite("Attached schemas")
struct AttachedSchemaTests {
    @Test("a query reads a table from an attached database")
    func readsFromAttachedSchema() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: icons.name)]
        )

        let paths = try await database.read { reader in
            try reader.fetchAll(AuxIcon.all().order(by: { $0.id }).query()).map(\.path)
        }

        #expect(paths == ["rifter.png", "raven.png"])
        withExtendedLifetime((main, icons)) {}
    }

    @Test("a join across schema boundaries")
    func joinsAcrossSchemas() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: icons.name)]
        )

        let rows = try await database.read { reader -> [String] in
            let query = TypeInfo.all()
                .join(AuxIcon.self) { type, icon in icon.typeID == type.id }
                .query()
            return try reader.fetchAll(query).map { "\($0.left.name):\($0.right.path)" }
        }

        #expect(Set(rows) == ["Rifter:rifter.png", "Raven:raven.png"])
        withExtendedLifetime((main, icons)) {}
    }

    @Test("the schema name is stored unescaped and escaped in SQL")
    func schemaNameIsNotDoubleEscaped() {
        // The quote used to be doubled in the initializer and again at render time,
        // making the schema impossible to find.
        let file = DatabaseFile(schemaName: #"we"ird"#)
        #expect(file.schemaName == #"we"ird"#)
        #expect(file.schemaName.quotedIdentifier == #""we""ird""#)
    }

    @Test("the URI goes into ATTACH as an escaped string literal")
    func uriIsEscapedForAttach() {
        #expect("it's".quotedStringLiteral == "'it''s'")
    }
}

