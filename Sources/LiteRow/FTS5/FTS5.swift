//
//  FTS5.swift
//  LiteRow
//

// Full-text search uses the regular builder: `MATCH`, a few functions and the virtual table's
// hidden columns. Two invariants: the search string is always bound as a **parameter** (the SQL
// text is the statement cache key), and hidden columns (`rank`, `rowid`) never enter `descriptor`.

// MARK: - Table occurrence as an expression

/// An FTS5 table as a value: `t0."invTypes_fts"`.
///
/// Used on the left of `MATCH` and as the first argument of FTS5 auxiliary functions.
/// FTS5 declares a hidden column named after the table; with aliases (`t0`) it must be
/// written qualified, since `t0 MATCH ?` fails with `no such column: t0`.
public struct TableExpression<Root: Table>: Expression<String> {
    public var table: TableRef<Root>

    @inlinable public init(_ table: TableRef<Root>) {
        self.table = table
    }

    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(alias: table.alias)
        sql.write(".")
        sql.write(Root.descriptor.quotedTableName)
    }
}

// MARK: - MATCH

extension TableRef {
    /// `t0 MATCH ?` over all indexed columns. Takes an `FTS5Pattern` so raw input cannot cause syntax errors.
    @inlinable public func match(
        _ pattern: FTS5Pattern
    ) -> BinaryExpression<Bool, TableExpression<Root>, ParameterExpression<String>> {
        .init(op: .match, left: TableExpression(self), right: .init(value: pattern.query))
    }
}

extension Expression where Value.Base == String {
    /// `t0."column" MATCH ?`, restricted to one column. Requires `detail=full` or `detail=column`.
    @inlinable public func match(
        _ pattern: FTS5Pattern
    ) -> BinaryExpression<Bool, Self, ParameterExpression<String>> {
        .init(op: .match, left: self, right: .init(value: pattern.query))
    }
}

// MARK: - Hidden columns

extension TableRef {
    /// The hidden `rank` column: bm25 relevance with all weights set to 1 by default.
    @inlinable public var rank: ColumnExpression<Double, Root> {
        .init(table: self, quotedColumn: "\"rank\"")
    }

    /// The hidden `rowid` column. For an FTS5 table it links to the content table.
    /// Not available on `WITHOUT ROWID` tables.
    @inlinable public var rowID: ColumnExpression<Int64, Root> {
        .init(table: self, quotedColumn: "\"rowid\"")
    }

    /// The `rowid` column typed as the content table's key, e.g. for `t0."rowid" = t1."typeID"`.
    @inlinable public func rowID<Value: SQLiteValue>(
        as type: Value.Type
    ) -> ColumnExpression<Value, Root> {
        .init(table: self, quotedColumn: "\"rowid\"")
    }

    /// `t0."rank" MATCH ?`: ranking weights for this query only, bound as a parameter.
    @inlinable public func ranked(
        by ranking: FTS5Ranking
    ) -> BinaryExpression<Bool, ColumnExpression<Double, Root>, ParameterExpression<String>> {
        .init(op: .match, left: rank, right: .init(value: ranking.specification))
    }
}

// MARK: - Auxiliary functions

extension TableRef {
    /// `bm25(t0)`: relevance as an expression, usable in a projection.
    @inlinable public func bm25() -> CallExpression<Double, TableExpression<Root>> {
        .init(call: "bm25", args: TableExpression(self))
    }

    /// `snippet(t0, …)`: text around the match, highlighted. `NULL` for `content=''` tables.
    ///
    /// - Parameters:
    ///   - column: Column index; `-1` picks the best match.
    ///   - start: Text inserted before a match.
    ///   - end: Text inserted after a match.
    ///   - ellipsis: Text marking a truncated edge.
    ///   - tokens: Number of tokens to return, 1…64.
    @inlinable public func snippet(
        column: Int32 = -1,
        start: String = "[",
        end: String = "]",
        ellipsis: String = "…",
        tokens: Int32 = 16
    ) -> CallExpression<
        String,
        TableExpression<Root>,
        ParameterExpression<Int32>,
        ParameterExpression<String>,
        ParameterExpression<String>,
        ParameterExpression<String>,
        ParameterExpression<Int32>
    > {
        .init(
            call: "snippet",
            args: (
                TableExpression(self),
                .init(value: column),
                .init(value: start),
                .init(value: end),
                .init(value: ellipsis),
                .init(value: tokens)
            )
        )
    }

    /// `highlight(t0, …)`: the whole column with matches highlighted.
    @inlinable public func highlight(
        column: Int32,
        start: String = "[",
        end: String = "]"
    ) -> CallExpression<
        String,
        TableExpression<Root>,
        ParameterExpression<Int32>,
        ParameterExpression<String>,
        ParameterExpression<String>
    > {
        .init(
            call: "highlight",
            args: (
                TableExpression(self),
                .init(value: column),
                .init(value: start),
                .init(value: end)
            )
        )
    }
}

// MARK: - Ranking

/// A ranking specification for a `rank` constraint, e.g. `bm25(10.0, 1.0)`.
///
/// Weights follow column order; missing weights default to 1.
public struct FTS5Ranking: Sendable, Hashable {
    public let specification: String

    /// A raw specification, e.g. for a custom auxiliary function.
    @inlinable public init(unsafe specification: String) {
        self.specification = specification
    }

    /// `bm25(w0, w1, …)`: per-column weights.
    public static func bm25(weights: [Double]) -> FTS5Ranking {
        guard !weights.isEmpty else { return FTS5Ranking(unsafe: "bm25()") }
        return FTS5Ranking(unsafe: "bm25(\(weights.map { "\($0)" }.joined(separator: ", ")))")
    }
}
