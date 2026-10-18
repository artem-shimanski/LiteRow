//
//  Subquery.swift
//  LiteRow
//

/// A query that can write itself into another query's `SQLWriter`, sharing its alias
/// numbering and parameter order.
///
/// `Output` lets the compiler check the subquery's shape, e.g. `IN` requires `Scalar<_>`.
public protocol Subquery<Output>: Sendable {
    associatedtype Output: RowDecodable

    func write(to sql: inout SQLWriter)

    /// Writes the query as an operand of a compound `SELECT` (`UNION` etc.).
    ///
    /// SQLite forbids `ORDER BY` and `LIMIT` on operands, so a query that has them wraps
    /// itself in `SELECT * FROM (…)`. Defaults to `write(to:)`.
    func writeAsOperand(to sql: inout SQLWriter)
}

extension Subquery {
    @inlinable public func writeAsOperand(to sql: inout SQLWriter) {
        write(to: &sql)
    }
}

extension QueryBuilder: Subquery {}

/// `x IN (SELECT …)` / `x NOT IN (SELECT …)`.
///
/// The subquery may be **correlated**: an outer reference captured in the subquery's closure
/// resolves to the outer query's table. A reference from a query not part of this `SELECT`
/// is a precondition failure.
///
/// If literally the same builder is used both outside and inside, the inner scope shadows
/// the outer one; start the subquery with a separate `all()`.
public struct InSubqueryExpression<Base: Expression, Sub: Subquery>: Expression<Bool> {
    public var base: Base
    public var subquery: Sub
    public var negated: Bool

    @inlinable public init(base: Base, subquery: Sub, negated: Bool = false) {
        self.base = base
        self.subquery = subquery
        self.negated = negated
    }

    @inlinable public var precedence: Int {
        SQLOperator.equal.precedence
    }

    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(base, minimumPrecedence: SQLOperator.equal.precedence + 1)
        sql.write(negated ? " NOT IN (" : " IN (")
        subquery.write(to: &sql)
        sql.write(")")
    }
}

// MARK: - IN (SELECT …)

extension Expression where Value: Equatable {
    /// `x IN (SELECT column FROM …)`; the subquery must project a single column.
    @inlinable public func `in`<V: SQLiteValue, Sub: Subquery<Scalar<V>>>(
        _ subquery: Sub
    ) -> InSubqueryExpression<Self, Sub> where V.Base == Value.Base {
        .init(base: self, subquery: subquery)
    }

    /// `x NOT IN (SELECT column FROM …)`.
    ///
    /// If the subquery returns any `NULL`, `NOT IN` matches no rows (standard SQL semantics).
    @inlinable public func notIn<V: SQLiteValue, Sub: Subquery<Scalar<V>>>(
        _ subquery: Sub
    ) -> InSubqueryExpression<Self, Sub> where V.Base == Value.Base {
        .init(base: self, subquery: subquery, negated: true)
    }
}

// MARK: - EXISTS

/// `EXISTS (SELECT …)`.
///
/// Mostly useful with a correlated subquery. The subquery's projection is not constrained.
public struct ExistsExpression<Sub: Subquery>: Expression<Bool> {
    public var subquery: Sub
    public var negated: Bool

    @inlinable public init(subquery: Sub, negated: Bool = false) {
        self.subquery = subquery
        self.negated = negated
    }

    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(negated ? "NOT EXISTS (" : "EXISTS (")
        subquery.write(to: &sql)
        sql.write(")")
    }
}

/// `EXISTS (SELECT …)`: at least one row exists.
@inlinable public func exists<Sub: Subquery>(_ subquery: Sub) -> ExistsExpression<Sub> {
    .init(subquery: subquery)
}

/// `NOT EXISTS (SELECT …)`: no rows exist. Unlike `NOT IN`, unaffected by `NULL`s.
@inlinable public func notExists<Sub: Subquery>(_ subquery: Sub) -> ExistsExpression<Sub> {
    .init(subquery: subquery, negated: true)
}
