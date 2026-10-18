//
//  SQLite.swift
//  LiteRow
//
//  Created by Artem Shimanski on 08.08.2026.
//

import SQLite3

@usableFromInline struct SQLiteConnectionHandle: ~Copyable {
    @usableFromInline typealias RawHandle = OpaquePointer
    @usableFromInline let rawHandle: RawHandle

    consuming func close() {
        sqlite3_close_v2(rawHandle)
        discard self
    }

    deinit {
        sqlite3_close_v2(rawHandle)
    }
}

public struct SQLiteStatementHandle: ~Copyable {
    public typealias RawHandle = OpaquePointer
    package let rawHandle: RawHandle

    init(rawHandle: RawHandle) {
        self.rawHandle = rawHandle
    }

    /// Takes ownership of a statement prepared outside LiteRow (used by `LiteRowBuild`).
    ///
    /// `deinit` finalizes the statement, so never pass a pointer that someone else finalizes.
    @_spi(Build)
    public init(owning rawHandle: RawHandle) {
        self.rawHandle = rawHandle
    }

    consuming func finalize() {
        sqlite3_finalize(rawHandle)
        discard self
    }

    deinit {
        sqlite3_finalize(rawHandle)
    }
}

enum SQLiteDestructor {
    static var transient: sqlite3_destructor_type {
        unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
    }
}


@inline(__always)
@inlinable func expectOK(_ code: Int32, statement: SQLiteStatementHandle.RawHandle, sql: String? = nil) throws(LiteRowError) {
    guard code != SQLITE_OK else { return }
    throw LiteRowError.sqlite(SQLiteFailure.current(code: code, statement: statement, sql: sql))
}

@inline(__always)
@inlinable func expectOK(_ code: Int32, connection: borrowing SQLiteConnectionHandle, sql: String? = nil) throws(LiteRowError) {
    guard code != SQLITE_OK else { return }
    throw LiteRowError.sqlite(SQLiteFailure.current(code: code, connection: connection.rawHandle, sql: sql))
}
