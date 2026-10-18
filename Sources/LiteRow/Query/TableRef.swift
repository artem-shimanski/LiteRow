//
//  TableRef.swift
//  LiteRow
//
//  Created by Artem Shimanski on 13.08.2026.
//

import Synchronization

/// The identity of a query that table occurrences belong to.
///
/// Assigned from a global counter once per `all()` chain. It never appears in SQL: scopes
/// are renumbered from zero when rendering, so the SQL text stays a stable cache key.
/// It lets a reference captured inside a subquery resolve to the outer query's table.
public struct QueryID: Sendable, Hashable {
    @usableFromInline let rawValue: Int

    @usableFromInline init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// No scope yet (initial `SQLWriter` state). The counter starts at 1, so 0 is never a real scope.
    @usableFromInline static let unassigned = QueryID(rawValue: 0)

    static func next() -> QueryID {
        QueryID(rawValue: queryCounter.wrappingAdd(1, ordering: .relaxed).newValue)
    }
}

private let queryCounter = Atomic<Int>(0)

/// The identity of one table occurrence in a query (a table can occur several times, e.g. in a self-join).
///
/// `id` is the position within the query's scope; the rendered alias adds the scope's base.
public struct TableAlias: Sendable, Hashable {
    public let query: QueryID
    public let id: Int

    @inlinable public init(query: QueryID, id: Int) {
        self.query = query
        self.id = id
    }
}

@dynamicMemberLookup
public struct TableRef<Root: Table>: Sendable, Hashable {
    public typealias Alias = TableAlias

    public let alias: Alias
    public init(alias: Alias) {
        self.alias = alias
    }

    @inlinable
    public subscript<Value>(_ keyPath: KeyPath<Root.Columns, Column<Root, Value>>) -> ColumnExpression<Value, Root> {
        .init(table: self, quotedColumn: Root.columns[keyPath: keyPath].quotedName)
    }

    @inlinable
    public subscript<Value>(dynamicMember keyPath: KeyPath<Root.Columns, Column<Root, Value>>) -> ColumnExpression<Value, Root> {
        self[keyPath]
    }
}

// `TableRef` does not write `schema.table AS t0` itself: the schema of an occurrence is held
// by the builder (it can be overridden with `all(in:)` / `join(_:in:)`), not by the type.

extension TableAlias: SQLWritable {
    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(alias: self)
    }
}

/// Precomputed alias names `t0`, `t1`, …, to avoid string interpolation per column.
@usableFromInline
let aliasNames: [String] = (0..<32).map { "t\($0)" }

@inlinable
func aliasName(_ id: Int) -> String {
    id < aliasNames.count ? aliasNames[id] : "t\(id)"
}
