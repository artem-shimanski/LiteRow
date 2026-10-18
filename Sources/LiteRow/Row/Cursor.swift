//
//  Cursor.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

import SQLite3

public struct Cursor<Output: RowDecodable>: ~Copyable {
    var statement: PreparedStatement<Output>
    private let rawHandle: SQLiteStatementHandle.RawHandle

    init(statement: consuming PreparedStatement<Output>) {
        rawHandle = statement.rawHandle
        self.statement = statement
    }

    public mutating func next() throws(LiteRowError) -> Output? {
        guard try statement.step() else { return nil }
        return try Output(Row(statement: rawHandle), offset: 0)
    }

    public consuming func finalize() {
        statement.finalize()
    }
}
