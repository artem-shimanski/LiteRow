//
//  Statement.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

import SQLite3

final class Statement {
    let handle: SQLiteStatementHandle
    let sql: String

    private init(rawHandle: SQLiteStatementHandle.RawHandle, sql: String) {
        self.handle = SQLiteStatementHandle(rawHandle: rawHandle)
        self.sql = sql
    }

    static func prepare(
        connection: borrowing SQLiteConnectionHandle,
        sql: String
    ) throws(LiteRowError) -> Statement {
        var rawHandle: SQLiteStatementHandle.RawHandle?
        let code = sqlite3_prepare_v2(connection.rawHandle, sql, -1, &rawHandle, nil)
        guard code == SQLITE_OK, let rawHandle else {
            sqlite3_finalize(rawHandle)
            throw LiteRowError.sqlite(SQLiteFailure.current(code: code, connection: connection.rawHandle, sql: sql))
        }
        return Statement(rawHandle: rawHandle, sql: sql)
    }

    func bind<Value: SQLiteValue>(_ value: Value, at parameter: Int32) throws(LiteRowError) {
        try value.bind(to: handle.rawHandle, at: parameter)
    }

    func step() throws(LiteRowError) -> Bool {
        let status = sqlite3_step(handle.rawHandle)
        switch status {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw .sqlite(SQLiteFailure.current(code: status, statement: handle.rawHandle, sql: sql))
        }
    }

    func reset() {
        sqlite3_reset(handle.rawHandle)
        sqlite3_clear_bindings(handle.rawHandle)
    }
}

/// A statement ready to execute, with its values already bound.
public struct PreparedStatement<Output: RowDecodable>: ~Copyable {
    let statement: Statement
    let cache: StatementCache
    let rawHandle: SQLiteStatementHandle.RawHandle

    init(statement: Statement, cache: StatementCache) {
        self.statement = statement
        self.cache = cache
        self.rawHandle = statement.handle.rawHandle
    }

    /// Binds one argument by position.
    func bind<Value: SQLiteValue>(_ value: Value, at parameter: Int32) throws(LiteRowError) {
        try statement.bind(value, at: parameter)
    }

    func step() throws(LiteRowError) -> Bool {
        try statement.step()
    }

    public consuming func fetch() -> Cursor<Output> {
        Cursor(statement: self)
    }

    public consuming func fetchAll(minimumCapacity: Int = 0) throws(LiteRowError) -> [Output] {
        var result = [Output]()
        result.reserveCapacity(minimumCapacity)
        var cursor = fetch()
        while let item = try cursor.next() {
            result.append(item)
        }
        return result
    }

    public consuming func fetchOne() throws(LiteRowError) -> Output? {
        var cursor = fetch()
        return try cursor.next()
    }

    public consuming func finalize() {}

    deinit {
        statement.reset()
        cache.release(statement)
    }
}
