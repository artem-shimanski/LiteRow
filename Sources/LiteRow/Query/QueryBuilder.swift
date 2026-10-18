//
//  QueryBuilder.swift
//  LiteRow
//
//  Created by Artem Shimanski on 12.08.2026.
//

public enum Order: String, Sendable, Hashable {
    case ascending = "ASC"
    case descending = "DESC"
}

extension Never: SQLiteValue {
    public static var storageClass: StorageClass {
        fatalError("Never cannot be evaluated")
    }

    public init(from row: borrowing Row, at column: Int32) throws(LiteRowError) {
        fatalError("Never cannot be evaluated")
    }

    public func bind(to statement: SQLiteStatementHandle.RawHandle, at parameter: Int32) throws(LiteRowError) {
        fatalError("Never cannot be evaluated")
    }

    public var binding: SQLiteBinding {
        fatalError("Never cannot be evaluated")
    }
}

extension Never: Expression {
    public typealias Value = Never

    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        fatalError("Never cannot be evaluated")
    }
}

public enum JoinKind: String, Sendable, Hashable {
    case inner = "JOIN"
    case left = "LEFT JOIN"
    case cross = "CROSS JOIN"
}

/// An `ORDER BY` term: an expression with its direction.
public struct OrderTerm<By: Expression>: Expression<By.Value> {
    public var by: By
    public var order: Order

    @inlinable public init(by: By, order: Order) {
        self.by = by
        self.order = order
    }

    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(by)
        sql.write(" ")
        sql.write(order.rawValue)
    }
}

/// A joined table occurrence in `FROM`, type-erased for rendering.
struct JoinSlot: Sendable {
    var kind: JoinKind
    var alias: TableAlias
    var quotedSchemaName: String
    var quotedTableName: String
    var condition: (any Expression<Bool>)?
}

/// A table reference usable as a pack element; exposes its table type for closure parameters.
///
/// The pack lives in method parameters (`where Joined == (repeat each J)`) rather than in the
/// struct, which keeps long chains type-checkable.
public protocol JoinedTableRef<JoinedSource>: Sendable {
    associatedtype JoinedSource: Table

    var joinedRef: TableRef<JoinedSource> { get }
}

extension TableRef: JoinedTableRef {
    public typealias JoinedSource = Root

    @inlinable public var joinedRef: TableRef<Root> { self }
}

/// Writes a type-erased expression, parenthesized by precedence.
///
/// Not `sql.write(expression)`: for `any Expression` the type checker may pick the
/// `SQLWritable` overload, which silently drops parentheses.
@inline(__always)
func writeErased<E: Expression>(_ expression: E, to sql: inout SQLWriter, minimumPrecedence: Int) {
    if expression.precedence < minimumPrecedence {
        sql.write("(")
        expression.write(to: &sql, minimumPrecedence: minimumPrecedence)
        sql.write(")")
    }
    else {
        expression.write(to: &sql, minimumPrecedence: minimumPrecedence)
    }
}

/// A query builder.
///
/// - `Output` is what a result row decodes into, derived from the projection and joins.
/// - `Source` and `Joined` are the tables in the query; `Joined` is a tuple of `TableRef`s
///   that methods expand as a pack to pass references into closures.
///
/// Clauses are stored type-erased, so a builder can be extended conditionally:
///
/// ```swift
/// var query = TypeInfo.all()
/// if let groupID { query = query.filter { $0.groupID == groupID } }
/// if let text { query = query.filter { $0.name.like("\(text)%") } }
/// ```
public struct QueryBuilder<Output: RowDecodable, Source: Table, Joined: Sendable>: Sendable {
    var source: TableRef<Source>

    /// The source's quoted schema name; `all(in:)` can override the `@Table` default.
    var quotedSourceSchema: String

    var refs: Joined
    var joins: [JoinSlot]
    var projection: (any Expression)?
    var predicates: [any Expression<Bool>]
    var groupBy: [any Expression]
    var having: [any Expression<Bool>]
    var order: [any Expression]
    var limit: Int?
    var offset: Int
    var isDistinct: Bool

    init(source: TableRef<Source>,
         quotedSourceSchema: String,
         refs: Joined,
         joins: [JoinSlot],
         projection: (any Expression)?,
         predicates: [any Expression<Bool>],
         groupBy: [any Expression],
         having: [any Expression<Bool>],
         order: [any Expression],
         limit: Int?,
         offset: Int,
         isDistinct: Bool) {
        self.source = source
        self.quotedSourceSchema = quotedSourceSchema
        self.refs = refs
        self.joins = joins
        self.projection = projection
        self.predicates = predicates
        self.groupBy = groupBy
        self.having = having
        self.order = order
        self.limit = limit
        self.offset = offset
        self.isDistinct = isDistinct
    }
}

extension Table {
    /// A query over the whole table; the start of every chain.
    ///
    /// - Parameter schema: The schema to read the table from; `nil` uses the one declared
    ///   in `@Table`. Override it when the same table is attached under several names.
    public static func all(in schema: DatabaseFile? = nil) -> QueryBuilder<Self, Self, ()> {
        .init(source: .init(alias: .init(query: .next(), id: 0)),
              quotedSourceSchema: schema?.quotedSchemaName ?? descriptor.quotedSchemaName,
              refs: (), joins: [], projection: nil,
              predicates: [], groupBy: [], having: [], order: [],
              limit: nil, offset: 0, isDistinct: false)
    }
}

// MARK: - Clauses

extension QueryBuilder {
    /// Adds a `WHERE` condition; multiple calls are joined with `AND`.
    public func filter<each J: JoinedTableRef, P: Expression<Bool>>(
        _ predicate: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> P
    ) -> Self where Joined == (repeat each J) {
        var result = self
        result.predicates.append(predicate(source, repeat (each refs).joinedRef))
        return result
    }

    /// Adds an `ORDER BY` term; terms keep call order.
    public func order<each J: JoinedTableRef, V: SQLiteValue, E: Expression<V>>(
        by expression: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> E,
        _ direction: Order = .ascending
    ) -> Self where Joined == (repeat each J) {
        var result = self
        result.order.append(OrderTerm(by: expression(source, repeat (each refs).joinedRef), order: direction))
        return result
    }

    /// Adds a `GROUP BY` expression.
    public func group<each J: JoinedTableRef, V: SQLiteValue, E: Expression<V>>(
        by expression: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> E
    ) -> Self where Joined == (repeat each J) {
        var result = self
        result.groupBy.append(expression(source, repeat (each refs).joinedRef))
        return result
    }

    /// Adds a `HAVING` condition; multiple calls are joined with `AND`.
    public func having<each J: JoinedTableRef, P: Expression<Bool>>(
        _ predicate: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> P
    ) -> Self where Joined == (repeat each J) {
        var result = self
        result.having.append(predicate(source, repeat (each refs).joinedRef))
        return result
    }

    public func limit(_ count: Int, offset: Int = 0) -> Self {
        var result = self
        result.limit = count
        result.offset = offset
        return result
    }

    public func distinct() -> Self {
        var result = self
        result.isDistinct = true
        return result
    }
}

// MARK: - Join

extension QueryBuilder {
    func _join<each J: JoinedTableRef, NewOutput: RowDecodable, Other: Table, P: Expression<Bool>>(
        _ table: Other.Type,
        in schema: DatabaseFile?,
        kind: JoinKind,
        on condition: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>, TableRef<Other>) -> P
    ) -> QueryBuilder<NewOutput, Source, (repeat each J, TableRef<Other>)>
    where Joined == (repeat each J) {
        // A join adds an occurrence to the same `SELECT` scope.
        let ref = TableRef<Other>(alias: .init(query: source.alias.query, id: joins.count + 1))
        let p = applyPack(condition, to: (source, repeat (each refs).joinedRef, ref))
        var newJoins = joins
        newJoins.append(JoinSlot(kind: kind, alias: ref.alias,
                                 quotedSchemaName: schema?.quotedSchemaName ?? Other.descriptor.quotedSchemaName,
                                 quotedTableName: Other.descriptor.quotedTableName,
                                 condition: p))
        return .init(source: source, quotedSourceSchema: quotedSourceSchema,
                     refs: (repeat each refs, ref), joins: newJoins,
                     projection: projection, predicates: predicates, groupBy: groupBy,
                     having: having, order: order, limit: limit, offset: offset,
                     isDistinct: isDistinct)
    }

    public func join<each J: JoinedTableRef, Other: Table, P: Expression<Bool>>(
        _ table: Other.Type,
        in schema: DatabaseFile? = nil,
        on condition: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>, TableRef<Other>) -> P
    ) -> QueryBuilder<Join<Output, Other>, Source, (repeat each J, TableRef<Other>)>
    where Joined == (repeat each J) {
        _join(table, in: schema, kind: .inner, on: condition)
    }

    public func leftJoin<each J: JoinedTableRef, Other: Table, P: Expression<Bool>>(
        _ table: Other.Type,
        in schema: DatabaseFile? = nil,
        on condition: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>, TableRef<Other>) -> P
    ) -> QueryBuilder<Join<Output, Other?>, Source, (repeat each J, TableRef<Other>)>
    where Joined == (repeat each J) {
        _join(table, in: schema, kind: .left, on: condition)
    }

    public func crossJoin<each J: JoinedTableRef, Other: Table, P: Expression<Bool>>(
        _ table: Other.Type,
        in schema: DatabaseFile? = nil,
        on condition: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>, TableRef<Other>) -> P
    ) -> QueryBuilder<Join<Output, Other>, Source, (repeat each J, TableRef<Other>)>
    where Joined == (repeat each J) {
        _join(table, in: schema, kind: .cross, on: condition)
    }
}

// MARK: - Projection

extension QueryBuilder {
    /// A scalar projection: one value per row.
    public func select<each J: JoinedTableRef, V: SQLiteValue, E: Expression<V>>(
        _ expression: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> E
    ) -> QueryBuilder<Scalar<E.Value>, Source, Joined>
    where Joined == (repeat each J) {
        .init(source: source, quotedSourceSchema: quotedSourceSchema, refs: refs, joins: joins,
              projection: expression(source, repeat (each refs).joinedRef),
              predicates: predicates, groupBy: groupBy, having: having, order: order,
              limit: limit, offset: offset, isDistinct: isDistinct)
    }

    /// A projection onto a tuple of expressions.
    public func select<each J: JoinedTableRef, each Rest: Expression>(
        _ expression: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> (repeat each Rest)
    ) -> QueryBuilder<Tuple<repeat (each Rest).Value>, Source, Joined>
    where Joined == (repeat each J) {
        let e = expression(source, repeat (each refs).joinedRef)
        return .init(source: source, quotedSourceSchema: quotedSourceSchema, refs: refs, joins: joins,
                     projection: CompoundExpression(of: Never.self, op: .coma, args: (repeat each e)),
                     predicates: predicates, groupBy: groupBy, having: having, order: order,
                     limit: limit, offset: offset, isDistinct: isDistinct)
    }

    /// A projection onto one table of the query; `Output` becomes that table.
    ///
    /// Useful when a join only filters rows (e.g. a `LEFT JOIN` used as a filter).
    public func select<each J: JoinedTableRef, T: Table>(
        _ ref: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> TableRef<T>
    ) -> QueryBuilder<T, Source, Joined>
    where Joined == (repeat each J) {
        let selected = ref(source, repeat (each refs).joinedRef)
        return .init(source: source, quotedSourceSchema: quotedSourceSchema, refs: refs, joins: joins,
                     projection: TableProjection<T>(alias: selected.alias),
                     predicates: predicates, groupBy: groupBy, having: having, order: order,
                     limit: limit, offset: offset, isDistinct: isDistinct)
    }

    /// A projection onto a named `@Projection` type, built with `Type.projection(field: expression, …)`.
    public func select<each J: JoinedTableRef, R: RowDecodable>(
        _ projection: (TableRef<Source>, repeat TableRef<(each J).JoinedSource>) -> Projection<R>
    ) -> QueryBuilder<R, Source, Joined>
    where Joined == (repeat each J) {
        let selected = projection(source, repeat (each refs).joinedRef)
        return .init(source: source, quotedSourceSchema: quotedSourceSchema, refs: refs, joins: joins,
                     projection: ProjectionList(columns: selected.columns),
                     predicates: predicates, groupBy: groupBy, having: having, order: order,
                     limit: limit, offset: offset, isDistinct: isDistinct)
    }

    /// `SELECT COUNT(*)`.
    public func count() -> QueryBuilder<Scalar<Int>, Source, Joined> {
        .init(source: source, quotedSourceSchema: quotedSourceSchema, refs: refs, joins: joins,
              projection: CallExpression<Int, RawExpression<Int>>(call: "COUNT", args: .init(raw: "*")),
              predicates: predicates, groupBy: groupBy, having: having, order: order,
              limit: limit, offset: offset, isDistinct: isDistinct)
    }
}

// MARK: - Rendering

extension QueryBuilder {
    /// Renders the SQL text and parameters in one pass.
    func render() -> (sql: String, bindings: [SQLiteBinding]) {
        var sql = SQLWriter()
        write(to: &sql)
        return (sql.sql, sql.bindings)
    }

    /// Writes the query into an existing writer, e.g. as a subquery of another query.
    public func write(to sql: inout SQLWriter) {
        // Opened before the projection, which already uses aliases.
        sql.beginScope(query: source.alias.query, aliasCount: 1 + joins.count)
        defer { sql.endScope() }

        sql.write("SELECT ")
        if isDistinct {
            sql.write("DISTINCT ")
        }
        if let projection {
            writeErased(projection, to: &sql, minimumPrecedence: 0)
        }
        else {
            sql.write("*")
        }

        sql.write(" FROM ")
        sql.write(quotedSourceSchema)
        sql.write(".")
        sql.write(Source.descriptor.quotedTableName)
        sql.write(" AS ")
        sql.write(alias: source.alias)

        for join in joins {
            sql.write(" ")
            sql.write(join.kind.rawValue)
            sql.write(" ")
            sql.write(join.quotedSchemaName)
            sql.write(".")
            sql.write(join.quotedTableName)
            sql.write(" AS ")
            sql.write(alias: join.alias)
            if let condition = join.condition {
                sql.write(" ON ")
                writeErased(condition, to: &sql, minimumPrecedence: 0)
            }
        }

        for (i, predicate) in predicates.enumerated() {
            sql.write(i == 0 ? " WHERE " : " AND ")
            writeErased(predicate, to: &sql,
                        minimumPrecedence: i == 0 ? SQLOperator.and.precedence
                                                  : SQLOperator.and.precedence + 1)
        }

        for (i, expression) in groupBy.enumerated() {
            sql.write(i == 0 ? " GROUP BY " : " , ")
            writeErased(expression, to: &sql,
                        minimumPrecedence: i == 0 ? SQLOperator.coma.precedence
                                                  : SQLOperator.coma.precedence + 1)
        }

        for (i, predicate) in having.enumerated() {
            sql.write(i == 0 ? " HAVING " : " AND ")
            writeErased(predicate, to: &sql,
                        minimumPrecedence: i == 0 ? SQLOperator.and.precedence
                                                  : SQLOperator.and.precedence + 1)
        }

        for (i, term) in order.enumerated() {
            sql.write(i == 0 ? " ORDER BY " : " , ")
            writeErased(term, to: &sql, minimumPrecedence: 0)
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

    public func makeSQL() -> String {
        render().sql
    }

    /// The finished query: SQL text plus bound values.
    public func query() -> SQLQuery<Output> {
        let rendered = render()
        return SQLQuery(rendered.sql, bindings: rendered.bindings)
    }
}

/// A single-table query without joins, as returned by `T.all()`.
public typealias Relation<T: Table> = QueryBuilder<T, T, ()>
