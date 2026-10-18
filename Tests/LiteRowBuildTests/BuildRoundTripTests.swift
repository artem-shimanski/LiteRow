//
//  BuildRoundTripTests.swift
//  LiteRowBuildTests
//

import Foundation
import Testing

import LiteRowBuild
@testable import LiteRow

/// Building and reading the same database with the same models.
///
/// These tests check that both sides agree, not the writing itself: if the column order in
/// `CREATE TABLE`, in `INSERT` and in the `SELECT` projection drifts apart, it fails right here.
@Suite("Build and read")
struct BuildRoundTripTests {
    private static let types = [
        TypeInfo(id: 1, name: "Rifter", groupID: 25),
        TypeInfo(id: 2, name: "Punisher", groupID: 25),
        TypeInfo(id: 3, name: "Raven", groupID: 27),
    ]

    private static let groups = [
        TypeGroup(id: 25, name: "Frigate", categoryID: 6),
        TypeGroup(id: 27, name: "Battleship", categoryID: 6),
    ]

    private static func memoryName() -> String {
        "literow-build-\(UUID().uuidString)"
    }

    @Test("a built database is readable with the same models")
    func buildsAndReads() async throws {
        let name = Self.memoryName()
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(TypeInfo.self, filledWith: Self.types)
        try builder.createIndexes(TypeInfo.self)

        // The write connection stays open: an in-memory database lives while any connection to it is open,
        // and without this anchor the reader would see an empty database.
        let database = try Database(main: .memory(name: name), attached: [:])

        let names = try await database.read { reader in
            try reader.fetchAll(TypeInfo.all().order(by: { $0.id }).query()).map(\.name)
        }

        #expect(names == ["Rifter", "Punisher", "Raven"])
        withExtendedLifetime(builder) {}
    }

    @Test("join over built tables")
    func joinsBuiltTables() async throws {
        let name = Self.memoryName()
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.transaction {
            try builder.create(TypeInfo.self, filledWith: Self.types)
            try builder.create(TypeGroup.self, filledWith: Self.groups)
        }
        try builder.createIndexes(TypeInfo.self)
        try builder.createIndexes(TypeGroup.self)

        let database = try Database(main: .memory(name: name), attached: [:])
        let rows = try await database.read { reader -> [String] in
            let query = TypeInfo.all()
                .join(TypeGroup.self) { type, group in type.groupID == group.id }
                .order(by: { type, _ in type.id })
                .query()
            return try reader.fetchAll(query).map { "\($0.left.name)/\($0.right.name)" }
        }

        #expect(rows == ["Rifter/Frigate", "Punisher/Frigate", "Raven/Battleship"])
        withExtendedLifetime(builder) {}
    }

    @Test("a composite key and typed IDs survive writing and reading")
    func compositeKeyRoundTrip() async throws {
        let name = Self.memoryName()
        let builder = try DatabaseBuilder(inMemory: name)
        let attributes = [
            TypeAttribute(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 4), value: 1200),
            TypeAttribute(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 9), value: 350),
        ]
        // WITHOUT ROWID: the table is read only by the whole key, an extra b-tree is pointless.
        try builder.create(TypeAttribute.self, filledWith: attributes, options: .keyOrdered)

        let database = try Database(main: .memory(name: name), attached: [:])
        let key = TypeAttribute.PrimaryKey.Key(typeID: TypeID(rawValue: 1), attributeID: AttributeID(rawValue: 9))
        let row = try await database.read { reader in
            try reader.fetchOne(TypeAttribute.self, key: key)
        }

        #expect(row?.value == 350)
        #expect(row?.primaryKey == key)
        withExtendedLifetime(builder) {}
    }

    @Test("NULL in an optional column reaches the read")
    func nullRoundTrip() async throws {
        let name = Self.memoryName()
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(
            OptionalRow.self,
            filledWith: [
                OptionalRow(id: 1, note: nil, weight: nil),
                OptionalRow(id: 2, note: "note", weight: 1.5),
            ]
        )

        let database = try Database(main: .memory(name: name), attached: [:])
        let rows = try await database.read { reader in
            try reader.fetchAll(OptionalRow.all().order(by: { $0.id }).query())
        }

        #expect(rows.map(\.note) == [nil, "note"])
        #expect(rows.map(\.weight) == [nil, 1.5])
        withExtendedLifetime(builder) {}
    }

    @Test("STRICT rejects a value of the wrong type")
    func strictRejectsMismatch() throws {
        let builder = try DatabaseBuilder(inMemory: Self.memoryName())
        try builder.create(TypeInfo.self)

        // The typed API cannot produce such a row; this checks that the schema also catches a mismatch
        // for what arrives bypassing the models, from raw SQL. The text goes into `groupID`: without STRICT
        // a plain INTEGER column would accept it and store it as text, and the app would only find out
        // when decoding.
        #expect(throws: LiteRowError.self) {
            try builder.execute(#"INSERT INTO "main"."invTypes" VALUES (1, 'Rifter', 'нет')"#)
        }
        withExtendedLifetime(builder) {}
    }

    @Test("ANALYZE puts statistics into the file")
    func analyzeWritesStatistics() async throws {
        let name = Self.memoryName()
        let builder = try DatabaseBuilder(inMemory: name)
        try builder.create(TypeInfo.self, filledWith: Self.types)
        try builder.createIndexes(TypeInfo.self)
        try builder.analyze()

        let database = try Database(main: .memory(name: name), attached: [:])
        let count = try await database.read { reader in
            try reader.fetchOne(
                SQLQuery<Scalar<Int>>("SELECT COUNT(*) FROM sqlite_master WHERE name = 'sqlite_stat1'")
            )?.value
        }

        #expect(count == 1)
        withExtendedLifetime(builder) {}
    }

    @Test("transaction rollback cancels the insert")
    func rollbackDiscardsRows() async throws {
        struct Interrupted: Error {}

        let name = Self.memoryName()
        // In-memory journal: with `journalMode == .off` there is nothing to roll back with, which is the
        // deliberate build default; this checks that the transaction mechanics still work.
        let builder = try DatabaseBuilder(inMemory: name, options: .init(journalMode: .memory))
        try builder.create(TypeInfo.self)

        #expect(throws: Interrupted.self) {
            try builder.transaction {
                try builder.insert(Self.types)
                throw Interrupted()
            }
        }

        let database = try Database(main: .memory(name: name), attached: [:])
        let count = try await database.read { reader in
            try reader.fetchOne(TypeInfo.all().count().query())?.value
        }

        // The nested transaction inside `insert` attached itself to the outer one, so COMMIT
        // did not happen and there are no rows in the database.
        #expect(count == 0)
        withExtendedLifetime(builder) {}
    }
}

@Suite("File on disk")
struct BuildFileTests {
    @Test("vacuum into gives a file that is readable and drags no journal along")
    func vacuumIntoFile() async throws {
        let directory = URL.temporaryDirectory.appending(
            path: "literow-build-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)
        let builder = try DatabaseBuilder(inMemory: "literow-build-\(UUID().uuidString)")
        try builder.create(
            TypeInfo.self,
            filledWith: [TypeInfo(id: 1, name: "Rifter", groupID: 25)]
        )
        try builder.createIndexes(TypeInfo.self)
        try builder.vacuum(into: url)
        builder.close()

        // Regression: `VACUUM INTO` opens the target with the same VFS as the main database, so for an
        // in-memory build the file went to `memdb`, with no error and no file on disk.
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        // Reading opens the file with `immutable=1`, and SQLite ignores the journal then:
        // a forgotten `-wal` next to it would give silently wrong data, not an error.
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false) + "-wal"))

        let database = try Database(url: url)
        let name = try await database.read { reader in
            try reader.fetchOne(TypeInfo.self, key: 1)?.name
        }

        #expect(name == "Rifter")
    }

    @Test("an existing file is rebuilt, not appended to")
    func recreatesExistingFile() async throws {
        let directory = URL.temporaryDirectory.appending(
            path: "literow-build-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)

        for _ in 0 ..< 2 {
            let builder = try DatabaseBuilder(creating: url)
            try builder.create(
                TypeInfo.self,
                filledWith: [TypeInfo(id: 1, name: "Rifter", groupID: 25)]
            )
            builder.close()
        }

        // The second run must not hit "table already exists" or double the rows.
        let database = try Database(url: url)
        let count = try await database.read { reader in
            try reader.fetchOne(TypeInfo.all().count().query())?.value
        }
        #expect(count == 1)
    }
}
