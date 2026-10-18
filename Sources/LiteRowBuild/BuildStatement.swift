//
//  BuildStatement.swift
//  LiteRowBuild
//

import SQLite3

@_spi(Build) import LiteRow

/// A prepared write statement that lives for the whole build (unlike the cached `PreparedStatement`).
final class BuildStatement {
    /// Owns the pointer: the handle's `deinit` finalizes the statement.
    let handle: SQLiteStatementHandle

    /// The same pointer, non-owning; never finalize it from here.
    private let raw: OpaquePointer

    let sql: String

    private init(rawHandle: OpaquePointer, sql: String) {
        self.handle = SQLiteStatementHandle(owning: rawHandle)
        self.raw = rawHandle
        self.sql = sql
    }

    static func prepare(connection: OpaquePointer, sql: String) throws(LiteRowError) -> BuildStatement {
        var rawHandle: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &rawHandle, nil)
        guard code == SQLITE_OK, let rawHandle else {
            sqlite3_finalize(rawHandle)
            throw LiteRowError.sqlite(SQLiteFailure.current(code: code, connection: connection, sql: sql))
        }
        return BuildStatement(rawHandle: rawHandle, sql: sql)
    }

    /// Runs a statement that returns a single integer, e.g. `PRAGMA user_version`.
    func integer() throws(LiteRowError) -> Int32 {
        let status = sqlite3_step(raw)
        defer { sqlite3_reset(raw) }
        guard status == SQLITE_ROW else {
            throw LiteRowError.sqlite(SQLiteFailure.current(code: status, statement: raw, sql: sql))
        }
        return sqlite3_column_int(raw, 0)
    }

    /// Runs a statement that returns no rows.
    func run() throws(LiteRowError) {
        let status = sqlite3_step(raw)
        // Reset before checking: otherwise the next bind fails with SQLITE_MISUSE and hides the original error.
        sqlite3_reset(raw)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw LiteRowError.sqlite(SQLiteFailure.current(code: status, statement: raw, sql: sql))
        }
    }
}
