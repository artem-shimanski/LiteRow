//
//  SchemaVersionTests.swift
//  LiteRowTests
//

import Foundation
import Testing
@testable import LiteRow

/// Build stamp: `user_version` and `application_id`.
///
/// A mismatched build does not look like an error: files from different builds open, queries run,
/// and the wrong names come out. So the check runs when a connection opens, before the first query.
@Suite("Build stamp: reading")
struct SchemaVersionTests {
    private static func stamped(_ sql: String, userVersion: Int32, applicationID: Int32 = 0) -> String {
        """
        PRAGMA user_version = \(userVersion);
        PRAGMA application_id = \(applicationID);
        \(sql)
        """
    }

    @Test("a matching stamp opens")
    func matchingVersionOpens() async throws {
        let fixture = try MemoryDatabaseFixture(sql: Self.stamped(TestSchema.sql, userVersion: 7))
        let database = try Database(
            main: .memory(name: fixture.name),
            attached: [:],
            options: Database.Options(schemaVersion: 7)
        )

        let count = try await database.read { reader in
            try reader.fetchOne(TypeInfo.all().count().query())?.value
        }

        #expect(count == 3)
        withExtendedLifetime(fixture) {}
    }

    @Test("a foreign build of the main file fails at open, not at query")
    func mismatchedMainVersionFailsOnOpen() throws {
        let fixture = try MemoryDatabaseFixture(sql: Self.stamped(TestSchema.sql, userVersion: 6))

        // The initializer throws: `mainConnection` is opened right away, so no query is needed.
        let error = #expect(throws: LiteRowError.self) {
            _ = try Database(
                main: .memory(name: fixture.name),
                attached: [:],
                options: Database.Options(schemaVersion: 7)
            )
        }
        guard case let .schemaMismatch(mismatch) = error else {
            Issue.record("expected schemaMismatch, got \(String(describing: error))")
            return
        }
        #expect(mismatch.schema == "main")
        #expect(mismatch.stamp == .userVersion)
        #expect(mismatch.expected == 7)
        #expect(mismatch.actual == 6)
        withExtendedLifetime(fixture) {}
    }

    @Test("a language file from another build is caught by its schema name")
    func mismatchedAttachedVersionIsReported() throws {
        // The main file is fresh while the language file is left over from an earlier build.
        let main = try MemoryDatabaseFixture(sql: Self.stamped(TestSchema.sql, userVersion: 7))
        let aux = try MemoryDatabaseFixture(sql: Self.stamped(TestSchema.iconsSQL, userVersion: 6))

        let error = #expect(throws: LiteRowError.self) {
            _ = try Database(
                main: .memory(name: main.name),
                attached: [.aux: .memory(name: aux.name)],
                options: Database.Options(schemaVersion: 7)
            )
        }
        guard case let .schemaMismatch(mismatch) = error else {
            Issue.record("expected schemaMismatch, got \(String(describing: error))")
            return
        }
        #expect(mismatch.schema == "aux")
        #expect(mismatch.actual == 6)
        withExtendedLifetime((main, aux)) {}
    }

    @Test("application_id is checked separately from the version")
    func applicationIDIsCheckedSeparately() throws {
        let fixture = try MemoryDatabaseFixture(
            sql: Self.stamped(TestSchema.sql, userVersion: 7, applicationID: 0x4C_52_30_31)
        )

        let error = #expect(throws: LiteRowError.self) {
            _ = try Database(
                main: .memory(name: fixture.name),
                attached: [:],
                options: Database.Options(schemaVersion: 7, applicationID: 0x4C_52_30_32)
            )
        }
        guard case let .schemaMismatch(mismatch) = error else {
            Issue.record("expected schemaMismatch, got \(String(describing: error))")
            return
        }
        #expect(mismatch.stamp == .applicationID)
        withExtendedLifetime(fixture) {}
    }

    @Test("nothing is checked without an expected stamp")
    func unstampedDatabaseOpensWithoutExpectation() async throws {
        // The default is `nil`: the library does not impose a stamp on those who do not need one.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let count = try await database.read { reader in
            try reader.fetchOne(TypeInfo.all().count().query())?.value
        }

        #expect(count == 3)
        withExtendedLifetime(fixture) {}
    }

    @Test("the stamp is checked on every pool connection, not only the main one")
    func everyPoolConnectionIsChecked() async throws {
        // The check lives in `Connection`, not `Database.init`: pool connections open lazily.
        let fixture = try MemoryDatabaseFixture(sql: Self.stamped(TestSchema.sql, userVersion: 7))
        let configuration = Database.Configuration(
            main: .memory(name: fixture.name),
            attached: [:],
            options: Database.Options(schemaVersion: 6)
        )

        #expect(throws: LiteRowError.self) {
            _ = try Connection(configuration)
        }
        withExtendedLifetime(fixture) {}
    }
}
