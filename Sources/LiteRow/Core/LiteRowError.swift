//
//  LiteRowError.swift
//  LiteRow
//
//  Created by Artem Shimanski on 08.08.2026.
//

import SQLite3

public enum LiteRowError: Error, Sendable {
    case cannotOpenDatabase(path: String, underlying: SQLiteFailure)
    case sqlite(SQLiteFailure)
    case decoding(DecodingFailure)
    case schemaMismatch(SchemaMismatch)
}

/// A database file's header stamp does not match what the app expects.
///
/// Checked when a connection opens, for `main` and every attached schema: files built
/// together from one source must carry the same stamp.
public struct SchemaMismatch: Error, Sendable, Hashable {
    /// Which header field did not match: `applicationID` identifies the file's owner,
    /// `userVersion` identifies the build.
    public enum Stamp: String, Sendable, Hashable {
        case userVersion = "user_version"
        case applicationID = "application_id"
    }

    /// The schema name as is (`main`, `loc`), unquoted.
    public let schema: String
    public let stamp: Stamp
    public let expected: Int32
    public let actual: Int32

    public init(schema: String, stamp: Stamp, expected: Int32, actual: Int32) {
        self.schema = schema
        self.stamp = stamp
        self.expected = expected
        self.actual = actual
    }
}

public struct SQLiteFailure: Error, Sendable, Hashable {
    public let code: Int32

    public let message: String

    public let sql: String?

    public init(code: Int32, message: String, sql: String? = nil) {
        self.code = code
        self.message = message
        self.sql = sql
    }
    
    /// `connection` may be `nil` (e.g. when `sqlite3_open_v2` failed); the message then
    /// falls back to the static text for the code.
    @inlinable package static func current(code: Int32, connection: OpaquePointer?, sql: String? = nil) -> SQLiteFailure {
        let message = connection.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
            ?? sqlite3_errstr(code).map { String(cString: $0) }
        return SQLiteFailure(code: code, message: message ?? "unknown error", sql: sql)
    }
    
    @inlinable package static func current(code: Int32, statement: OpaquePointer, sql: String? = nil) -> SQLiteFailure {
        current(code: code, connection: sqlite3_db_handle(statement), sql: sql)
    }
}

public struct DecodingFailure: Error, Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case unexpectedNull
        case typeMismatch(expected: StorageClass, actual: StorageClass?)
        case integerOutOfRange(Int64)
        case invalidRawValue(String)
    }

    public let table: String
    public let column: String
    public let columnIndex: Int32
    public let rowID: Int64?
    public let reason: Reason

    public init(
        table: String,
        column: String,
        columnIndex: Int32,
        rowID: Int64?,
        reason: Reason
    ) {
        self.table = table
        self.column = column
        self.columnIndex = columnIndex
        self.rowID = rowID
        self.reason = reason
    }
}

extension SQLiteFailure: CustomStringConvertible {
    public var description: String {
        var text = "SQLite \(code): \(message)"
        if let sql { text += "\n  SQL: \(sql)" }
        return text
    }
}

extension SchemaMismatch: CustomStringConvertible {
    public var description: String {
        "schema \(schema): \(stamp.rawValue) = \(actual), expected \(expected)"
    }
}

extension DecodingFailure: CustomStringConvertible {
    public var description: String {
        var text = "\(table).\(column) (column \(columnIndex))"
        if let rowID { text += ", rowid \(rowID)" }
        return "\(text): \(reason)"
    }
}
