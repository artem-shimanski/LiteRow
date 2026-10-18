//
//  Row.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

import SQLite3

public struct Row: ~Copyable, ~Escapable {
    @usableFromInline let statement: SQLiteStatementHandle.RawHandle
    
    @_lifetime(borrow statement)
    init(statement: SQLiteStatementHandle.RawHandle) {
        self.statement = statement
    }
    
    /// Storage class of the column's value; `nil` for NULL.
    @inlinable
    public func storageClass(at column: Int32) -> StorageClass? {
        StorageClass(columnType: sqlite3_column_type(statement, column))
    }

    @inlinable
    public func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
    
    @inlinable
    public func integer(at column: Int32) throws(LiteRowError) -> Int64 {
        try check(.integer, at: column)
        return sqlite3_column_int64(statement, column)
    }
    
    @inlinable
    public func double(at column: Int32) throws(LiteRowError) -> Double {
        try check(.real, at: column)
        return sqlite3_column_double(statement, column)
    }

    @inlinable
    public func text(at column: Int32) throws(LiteRowError) -> String {
        try check(.text, at: column)
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    @inlinable
    @_lifetime(borrow self)
    public func blob(at column: Int32) throws(LiteRowError) -> RawSpan? {
        try check(.blob, at: column)
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        
        let span = UnsafeRawBufferPointer(start: bytes, count: count).bytes
        return _overrideLifetime(span, borrowing: self)
    }
    
    @inlinable
    public func check(_ expected: StorageClass, at column: Int32) throws(LiteRowError) {
        let actual = sqlite3_column_type(statement, column)
        if actual == SQLITE_NULL {
            throw failure(.unexpectedNull, at: column)
        }
        if expected == .real, actual == SQLITE_INTEGER {
            return
        }
        let found = StorageClass(columnType: actual)
        guard found == expected else {
            throw failure(.typeMismatch(expected: expected, actual: found), at: column)
        }
    }
    
    public func failure(_ reason: DecodingFailure.Reason, at column: Int32) -> LiteRowError {
        let name = sqlite3_column_name(statement, column).map { String(cString: $0) }
        let table = "unimplemented"
        let rowID: Int64? = nil
        return .decoding(
            DecodingFailure(
                table: table,
                column: name ?? "column \(column)",
                columnIndex: column,
                rowID: rowID,
                reason: reason
            )
        )
    }
}
