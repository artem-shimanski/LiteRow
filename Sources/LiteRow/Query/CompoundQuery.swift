//
//  CompoundQuery.swift
//  LiteRow
//

/// A compound `SELECT` operator.
///
/// Operators apply left to right: `A UNION B EXCEPT C` is `(A UNION B) EXCEPT C`. To group
/// differently, nest a `CompoundQuery` as an operand (it is written as a subquery).
public enum CompoundOperator: String, Sendable, Hashable {
    /// Union with duplicates removed (rows compared on all columns).
    case union = "UNION"

    /// Union keeping duplicates; cheaper than `UNION`.
    case unionAll = "UNION ALL"

    /// Rows present in both operands.
    case intersect = "INTERSECT"

    /// Rows of the first operand that are not in the second.
    case except = "EXCEPT"
}

/// A compound `ORDER BY` term: a **result column number**, since operand columns are not
/// visible to a compound's `ORDER BY`.
struct CompoundOrderTerm: Sendable, Hashable {
    /// 1-based, as in SQL.
    var column: Int
    var order: Order
}

/// A compound `SELECT`: queries combined with `UNION` / `UNION ALL` / `INTERSECT` / `EXCEPT`.
///
/// For rows of the same shape coming from different tables, e.g. full-text search across
/// two language indexes.
///
/// ```swift
/// let en = TypeSearchIndex.all()
///     .join(TypeInfo.self) { fts, type in fts.rowID(as: UInt32.self) == type.id }
///     .filter { fts, _ in fts.match(pattern) }
///     .order(by: { fts, _ in fts.rank })
///     .limit(25)
///     .select { _, type in type }
/// let ru = /* the same over TypeSearchIndexRU */
///
/// let query = en.union(ru)
///     .order(by: \.name)
///     .limit(50)
///     .query()
/// ```
///
/// Operands are type-erased to `any Subquery<Output>`; a shared `Output` guarantees the same
/// column count and decoding order. Finish the chain with `query()`. A compound is also a
/// `Subquery`, so it can be used with `IN` and `EXISTS`.
public struct CompoundQuery<Output: RowDecodable>: Sendable {
    /// An operator with the operand it appends.
    struct Operand: Sendable {
        var op: CompoundOperator
        var query: any Subquery<Output>
    }

    var first: any Subquery<Output>
    var rest: [Operand]
    var order: [CompoundOrderTerm]
    var limit: Int?
    var offset: Int

    init(first: any Subquery<Output>,
         rest: [Operand],
         order: [CompoundOrderTerm] = [],
         limit: Int? = nil,
         offset: Int = 0) {
        self.first = first
        self.rest = rest
        self.order = order
        self.limit = limit
        self.offset = offset
    }
}

// MARK: - Building

extension Subquery {
    /// `A UNION B`: union with duplicates removed. Both operands must decode to the same `Output`.
    public func union<Other: Subquery<Output>>(_ other: Other) -> CompoundQuery<Output> {
        CompoundQuery(first: self, rest: [.init(op: .union, query: other)])
    }

    /// `A UNION ALL B`: union keeping duplicates.
    public func unionAll<Other: Subquery<Output>>(_ other: Other) -> CompoundQuery<Output> {
        CompoundQuery(first: self, rest: [.init(op: .unionAll, query: other)])
    }

    /// `A INTERSECT B`: rows present in both operands.
    public func intersect<Other: Subquery<Output>>(_ other: Other) -> CompoundQuery<Output> {
        CompoundQuery(first: self, rest: [.init(op: .intersect, query: other)])
    }

    /// `A EXCEPT B`: rows of the first operand that are not in the second.
    public func except<Other: Subquery<Output>>(_ other: Other) -> CompoundQuery<Output> {
        CompoundQuery(first: self, rest: [.init(op: .except, query: other)])
    }
}

extension CompoundQuery {
    /// Appends an operand to the same compound: `a.union(b).union(c)` is `A UNION B UNION C`.
    ///
    /// Must be called before `order`/`limit`, which apply to the whole compound.
    func appending<Other: Subquery<Output>>(_ op: CompoundOperator, _ other: Other) -> Self {
        precondition(
            order.isEmpty && limit == nil,
            "cannot add a compound operand after order/limit: they apply to the whole compound"
        )
        var result = self
        result.rest.append(.init(op: op, query: other))
        return result
    }

    public func union<Other: Subquery<Output>>(_ other: Other) -> Self {
        appending(.union, other)
    }

    public func unionAll<Other: Subquery<Output>>(_ other: Other) -> Self {
        appending(.unionAll, other)
    }

    public func intersect<Other: Subquery<Output>>(_ other: Other) -> Self {
        appending(.intersect, other)
    }

    public func except<Other: Subquery<Output>>(_ other: Other) -> Self {
        appending(.except, other)
    }
}

// MARK: - Clauses

extension CompoundQuery {
    /// `ORDER BY` a result column number, 1-based as in SQL. Works for any projection.
    public func order(byColumn column: Int, _ direction: Order = .ascending) -> Self {
        precondition(column >= 1, "result columns are numbered from 1")
        precondition(
            column <= Int(Output.width),
            "column \(column) with \(Output.width) columns in the projection"
        )
        var result = self
        result.order.append(CompoundOrderTerm(column: column, order: direction))
        return result
    }

    /// `LIMIT` / `OFFSET` of the whole compound. Limit an operand on the operand itself:
    /// `a.limit(25).union(b.limit(25))`.
    public func limit(_ count: Int, offset: Int = 0) -> Self {
        var result = self
        result.limit = count
        result.offset = offset
        return result
    }
}

extension CompoundQuery where Output: Table {
    /// `ORDER BY` a model column. Valid only when the operands project the whole table.
    public func order<V: SQLiteValue>(
        by keyPath: KeyPath<Output.Columns, Column<Output, V>>,
        _ direction: Order = .ascending
    ) -> Self {
        order(byColumn: Int(Output.columns[keyPath: keyPath].index) + 1, direction)
    }
}

// MARK: - Rendering

extension CompoundQuery: Subquery {
    /// Writes the compound. It opens no alias scope of its own; each operand opens its own.
    public func write(to sql: inout SQLWriter) {
        first.writeAsOperand(to: &sql)

        for operand in rest {
            sql.write(" ")
            sql.write(operand.op.rawValue)
            sql.write(" ")
            operand.query.writeAsOperand(to: &sql)
        }

        for (i, term) in order.enumerated() {
            sql.write(i == 0 ? " ORDER BY " : " , ")
            sql.write(String(term.column))
            sql.write(" ")
            sql.write(term.order.rawValue)
        }

        if let limit {
            sql.write(" LIMIT ")
            sql.write(parameter: Int64(limit))
            if offset > 0 {
                sql.write(" OFFSET ")
                sql.write(parameter: Int64(offset))
            }
        }
    }

    /// A nested compound is always written as `SELECT * FROM (…)`, which preserves grouping.
    public func writeAsOperand(to sql: inout SQLWriter) {
        sql.write("SELECT * FROM (")
        write(to: &sql)
        sql.write(")")
    }

    public func makeSQL() -> String {
        render().sql
    }

    /// The finished query: SQL text plus bound values.
    public func query() -> SQLQuery<Output> {
        let rendered = render()
        return SQLQuery(rendered.sql, bindings: rendered.bindings)
    }

    func render() -> (sql: String, bindings: [SQLiteBinding]) {
        var sql = SQLWriter()
        write(to: &sql)
        return (sql.sql, sql.bindings)
    }
}

// MARK: - A regular query as an operand

extension QueryBuilder {
    /// Writes the query as a compound operand.
    ///
    /// SQLite forbids `ORDER BY` and `LIMIT` on an operand, so a query with them is wrapped
    /// in `SELECT * FROM (…)`. The wrapper keeps the same columns in the same order.
    public func writeAsOperand(to sql: inout SQLWriter) {
        guard !order.isEmpty || limit != nil else {
            write(to: &sql)
            return
        }
        sql.write("SELECT * FROM (")
        write(to: &sql)
        sql.write(")")
    }
}
