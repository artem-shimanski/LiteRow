//
//  Fixtures.swift
//  LiteRowUITests
//

import Foundation
import SQLite3
import LiteRow

/// A populated in-memory database that can be opened through `Database.Source.memory`.
///
/// A copy of the fixture from `LiteRowTests`: test targets do not see each other, and a shared
/// target for twenty lines costs more than repeating them.
final class MemoryDatabaseFixture {
    let name: String
    private var handle: OpaquePointer?

    init(sql: String, name: String = "literow-ui-test-\(UUID().uuidString)") throws {
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
        guard sqlite3_exec(handle, sql, nil, nil, &rawMessage) == SQLITE_OK else {
            let message = rawMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(rawMessage)
            throw FixtureError(message: message)
        }
    }

    deinit { sqlite3_close_v2(handle) }

    struct FixtureError: Error { let message: String }
}

enum TestSchema {
    static let sql = """
        CREATE TABLE invTypes (
            typeID INTEGER PRIMARY KEY,
            typeName TEXT NOT NULL,
            groupID INTEGER NOT NULL
        );
        INSERT INTO invTypes VALUES (1, 'Rifter', 25), (2, 'Punisher', 25), (3, 'Raven', 27);
        """
}

@Table("invTypes")
struct TestType {
    @PrimaryKey @Column("typeID") var id: UInt32
    @Column("typeName") var name: String
    @Index var groupID: UInt32
}

/// A section header: one column, decoded by hand.
///
/// Its own struct rather than `Scalar<UInt32>`, for two reasons: the header has a field name
/// that is read in `ForEach`, and `Scalar` is not `Hashable`.
struct GroupSection: RowDecodable, Hashable {
    var groupID: UInt32

    static var width: Int32 { 1 }

    init(_ row: borrowing Row, offset: Int32) throws(LiteRowError) {
        groupID = try UInt32(from: row, at: offset)
    }

    init(groupID: UInt32) {
        self.groupID = groupID
    }
}

/// Counts calls to the error handler.
///
/// `@unchecked Sendable`: the test is single-threaded and entirely on the main actor, while the
/// handler is declared `@Sendable` because it lives in the environment.
final class ErrorLog: @unchecked Sendable {
    private(set) var errors: [any Error] = []
    var count: Int { errors.count }
    func append(_ error: any Error) { errors.append(error) }
}
