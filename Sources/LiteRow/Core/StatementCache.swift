//
//  StatementCache.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

/// Prepared statements of one connection, keyed by SQL text.
final class StatementCache {
    private var statements: [String: [Statement]] = [:]

    /// Values are not part of the key, so queries of the same shape share a statement.
    func acquire<Output: RowDecodable>(
        of output: Output.Type = Output.self,
        sql: String,
        makeStatement: @autoclosure () throws(LiteRowError) -> Statement
    ) throws(LiteRowError) -> PreparedStatement<Output> {
        let statement: Statement
        if let cached = statements[sql]?.popLast() {
            statement = cached
        }
        else {
            statement = try makeStatement()
        }
        let prepared = PreparedStatement<Output>(statement: statement, cache: self)
        return prepared
    }

    func release(_ statement: Statement) {
        statements[statement.sql, default: []].append(statement)
    }

    /// Finalizes all cached statements. Must run before the connection closes: finalizing
    /// a statement of a zombie connection left by `sqlite3_close_v2` crashes on Apple platforms.
    func removeAll() {
        statements.removeAll()
    }
}
