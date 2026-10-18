//
//  Query.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

import SQLite3

/// Binds query parameters sequentially.
public struct Binder: ~Copyable {
    @usableFromInline var statement: SQLiteStatementHandle.RawHandle

    /// Number of parameters bound so far. SQLite parameters are 1-based, so the next one is `bound + 1`.
    @usableFromInline var bound: Int32 = 0

    package init(statement: SQLiteStatementHandle.RawHandle, bound: Int32 = 0) {
        self.statement = statement
        self.bound = bound
    }

    @inlinable public mutating func bind(_ value: some SQLiteValue) throws(LiteRowError) {
        bound += 1
        try value.bind(to: statement, at: bound)
    }
    
    @inlinable public mutating func bindNull() throws(LiteRowError) {
        bound += 1
        try expectOK(sqlite3_bind_null(statement, bound), statement: statement)
    }

}

/// A query rendered to SQL text plus bound parameters.
///
/// `Output` is the type one result row decodes into (e.g. `Join<A, B>` for a join).
public protocol Query<Output>: Sendable, Hashable {
    associatedtype Output: RowDecodable
    var sql: String {get}
    func bind(to binder: inout Binder) throws(LiteRowError)
}
