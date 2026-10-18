//
//  SQLWriter.swift
//  LiteRow
//
//  Created by Artem Shimanski on 12.08.2026.
//

public protocol SQLWritable: Sendable {
    func write(to sql: inout SQLWriter, minimumPrecedence: Int)
}

public protocol SQLBindable: Sendable {
    func bind(to binder: inout Binder) throws(LiteRowError)
}

extension SQLWritable {
    @inlinable public func write(to sql: inout SQLWriter) {
        write(to: &sql, minimumPrecedence: 0)
    }

}

public struct SQLWriter: ~Copyable, Sendable {
    @usableFromInline var sql: String = ""

    /// Parameter values in the order of their `?` in the text; both are written by `write(parameter:)`.
    @usableFromInline var bindings: [SQLiteBinding] = []

    /// The current `SELECT` scope: its query, the first alias number, and the number of tables.
    @usableFromInline var currentQuery: QueryID = .unassigned
    @usableFromInline var currentBase: Int = 0
    @usableFromInline var currentCount: Int = 0

    /// Enclosing scopes, outermost first; empty unless there are subqueries.
    @usableFromInline var enclosing: [(query: QueryID, base: Int, count: Int)] = []

    /// Number of alias names handed out so far; alias names are unique across the whole statement.
    @usableFromInline var nextBase: Int = 0

    @inlinable public init() {
        sql.reserveCapacity(128)
    }

    /// Writes a table occurrence's alias: the scope's base plus the occurrence's position.
    @inlinable public mutating func write(alias: TableAlias) {
        if alias.query == currentQuery {
            precondition(
                alias.id < currentCount,
                "TableRef from another query: occurrence \(alias.id) with \(currentCount) tables in this SELECT"
            )
            write(aliasName(currentBase + alias.id))
        }
        else {
            writeEnclosing(alias)
        }
    }

    /// A reference to an enclosing query's table (a correlated subquery). Searches from the
    /// innermost scope outwards.
    @usableFromInline
    @inline(never)
    mutating func writeEnclosing(_ alias: TableAlias) {
        for scope in enclosing.reversed() where scope.query == alias.query {
            precondition(
                alias.id < scope.count,
                "TableRef from another query: occurrence \(alias.id) with \(scope.count) tables in its SELECT"
            )
            write(aliasName(scope.base + alias.id))
            return
        }
        preconditionFailure("TableRef from a query that is not part of this SELECT")
    }

    /// Opens a `SELECT` scope. Must be called **before** writing the projection, which already uses aliases.
    @inlinable public mutating func beginScope(query: QueryID, aliasCount count: Int) {
        // The outermost scope is not pushed, so a query without subqueries allocates nothing.
        if currentQuery != .unassigned {
            enclosing.append((currentQuery, currentBase, currentCount))
        }
        currentQuery = query
        currentBase = nextBase
        nextBase += count
        currentCount = count
    }

    @inlinable public mutating func endScope() {
        if let saved = enclosing.popLast() {
            currentQuery = saved.query
            currentBase = saved.base
            currentCount = saved.count
        }
        else {
            currentQuery = .unassigned
            currentBase = 0
            currentCount = 0
        }
    }

    @inlinable public mutating func write(_ text: some StringProtocol) {
        sql += text
    }

    /// Writes a `?` and records its value in one call.
    @inlinable public mutating func write(parameter value: some SQLiteValue) {
        sql += "?"
        bindings.append(value.binding)
    }

    /// Same, for a type-erased value.
    @inlinable public mutating func write(parameter binding: SQLiteBinding) {
        sql += "?"
        bindings.append(binding)
    }


    @inlinable public mutating func write(_ expresison: some Expression, minimumPrecedence: Int = 0) {
        let parenthesized = expresison.precedence < minimumPrecedence
        if parenthesized {
            write("(")
            expresison.write(to: &self, minimumPrecedence: minimumPrecedence)
            write(")")
        }
        else {
            expresison.write(to: &self, minimumPrecedence: minimumPrecedence)
        }
    }
    
    @inlinable public mutating func write(_ node: some SQLWritable, minimumPrecedence: Int = 0) {
        node.write(to: &self, minimumPrecedence: minimumPrecedence)
    }
    
    @discardableResult
    @inlinable public mutating func write<each N: SQLWritable>(_ nodes: (repeat each N), separator: String, minimumPrecedence: Int = 0) -> Int {
        var n = 0
        func append(_ node: some SQLWritable) {
            if n > 0, !separator.isEmpty { write(separator) }
            n += 1
            write(node, minimumPrecedence: minimumPrecedence)
        }
        (repeat append(each nodes))
        return n
    }
}
