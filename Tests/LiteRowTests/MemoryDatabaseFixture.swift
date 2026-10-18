//
//  MemoryDatabaseFixture.swift
//  LiteRowTests
//

import Foundation
import SQLite3

/// A populated in-memory database that can be opened through `Database.Source.memory`.
///
/// `Database` is read-only, so the fixture fills the database from outside. It also keeps it alive:
/// an in-memory database exists only while a connection to it is open, and this anchor
/// bridges the gap between filling and opening.
final class MemoryDatabaseFixture {
    let name: String
    private var handle: OpaquePointer?

    init(sql: String, name: String = "literow-test-\(UUID().uuidString)") throws {
        self.name = name

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            "file:/\(name)?vfs=memdb",
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw FixtureError(message: "sqlite3_open_v2 failed with \(status)")
        }
        self.handle = handle

        var rawMessage: UnsafeMutablePointer<CChar>?
        let execStatus = sqlite3_exec(handle, sql, nil, nil, &rawMessage)
        guard execStatus == SQLITE_OK else {
            let message = rawMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(rawMessage)
            throw FixtureError(message: message)
        }
    }

    /// Closes the anchor. From then on the database lives only as long as the other connections to it.
    func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    struct FixtureError: Error {
        let message: String
    }
}

/// A file database in a temporary directory, removed together with the fixture.
final class FileDatabaseFixture {
    let url: URL
    private let directory: URL

    init(sql: String) throws {
        directory = URL.temporaryDirectory.appending(path: "literow-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "test.sqlite", directoryHint: .notDirectory)

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw MemoryDatabaseFixture.FixtureError(message: "sqlite3_open_v2 failed with \(status)")
        }
        defer { sqlite3_close_v2(handle) }

        var rawMessage: UnsafeMutablePointer<CChar>?
        let execStatus = sqlite3_exec(handle, sql, nil, nil, &rawMessage)
        guard execStatus == SQLITE_OK else {
            let message = rawMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(rawMessage)
            throw MemoryDatabaseFixture.FixtureError(message: message)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Data

enum TestSchema {
    /// Matches the tables in `Examples.swift`, so tests use the same models.
    static let sql = """
        CREATE TABLE invTypes (
            typeID INTEGER PRIMARY KEY,
            typeName TEXT NOT NULL,
            groupID INTEGER NOT NULL
        );
        INSERT INTO invTypes VALUES (1, 'Rifter', 25), (2, 'Punisher', 25), (3, 'Raven', 27);

        CREATE TABLE invGroups (
            groupID INTEGER PRIMARY KEY,
            groupName TEXT NOT NULL,
            categoryID INTEGER NOT NULL
        );
        INSERT INTO invGroups VALUES (25, 'Frigate', 6), (27, 'Battleship', 6);

        CREATE TABLE dgmTypeAttributes (
            typeID INTEGER NOT NULL,
            attributeID INTEGER NOT NULL,
            value REAL NOT NULL,
            PRIMARY KEY (typeID, attributeID)
        );
        INSERT INTO dgmTypeAttributes VALUES (1, 4, 1200.0), (1, 9, 350.0), (3, 4, 99000.0);
        """

    static let iconsSQL = """
        CREATE TABLE eveIcons (
            iconID INTEGER PRIMARY KEY,
            typeID INTEGER NOT NULL,
            iconFile TEXT NOT NULL
        );
        INSERT INTO eveIcons VALUES (100, 1, 'rifter.png'), (101, 3, 'raven.png');
        """
}
