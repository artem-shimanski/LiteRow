//
//  Expression1.swift
//  LiteRow
//
//  Created by Artem Shimanski on 12.08.2026.
//

/// An SQL expression node. Parameters are written together with their `?` via
/// `SQLWriter.write(parameter:)`, in a single rendering pass.
public protocol Expression<Value>: Sendable, SQLWritable {
    associatedtype Value: SQLiteValue

    var precedence: Int {get}
}

extension Expression {
    @inlinable public var precedence: Int {.max}
}

public struct ParameterExpression<Value: SQLiteValue>: Expression<Value> {
    public var value: Value
    @inlinable public init(value: Value) {
        self.value = value
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(parameter: value)
    }
}

public struct ColumnExpression<Value: SQLiteValue, Root: Table>: Expression<Value> {
    public var table: TableRef<Root>

    /// The **already quoted** column name.
    public var quotedColumn: String

    @inlinable public init(table: TableRef<Root>, quotedColumn: String) {
        self.table = table
        self.quotedColumn = quotedColumn
    }

    @inlinable public init(of type: Value.Type, table: TableRef<Root>, quotedColumn: String) {
        self.table = table
        self.quotedColumn = quotedColumn
    }

    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(alias: table.alias)
        sql.write(".")
        sql.write(quotedColumn)
    }
}

/// A whole-table projection: all columns of one table occurrence, in `descriptor` order
/// (the order the generated `init(_ row:offset:)` decodes).
public struct TableProjection<Root: Table>: Expression<Never> {
    public var alias: TableRef<Root>.Alias

    @inlinable public init(alias: TableRef<Root>.Alias) {
        self.alias = alias
    }

    /// Comma precedence, like a `CompoundExpression` with `,`.
    @inlinable public var precedence: Int {
        SQLOperator.coma.precedence
    }

    public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        for (i, column) in Root.descriptor.columns.enumerated() {
            if i > 0 {
                sql.write(", ")
            }
            sql.write(alias: alias)
            sql.write(".")
            sql.write(column.quotedName)
        }
    }
}

public struct BinaryExpression<Value: SQLiteValue, Left: Expression, Right: Expression>: Expression<Value> {
    public var op: SQLOperator
    public var left: Left
    public var right: Right
    
    @inlinable public init(op: SQLOperator, left: Left, right: Right) {
        self.op = op
        self.left = left
        self.right = right
    }
    
    @inlinable public var precedence: Int {
        op.precedence
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(left, minimumPrecedence: op.precedence)
        sql.write(" ")
        sql.write(op.text)
        sql.write(" ")
        sql.write(right, minimumPrecedence: op.precedence + 1)
    }
}

public struct CompoundExpression<Value: SQLiteValue, each Arguments: Expression>: Expression<Value> {
    public var op: SQLOperator
    public var args: (repeat each Arguments)
    
    @inlinable public init(op: SQLOperator, args: (repeat each Arguments)) {
        self.op = op
        self.args = args
    }

    @inlinable public init(of type: Value.Type, op: SQLOperator, args: (repeat each Arguments)) {
        self.op = op
        self.args = args
    }

    @inlinable public var precedence: Int {
        op.precedence
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        if op == .coma {
            sql.write((repeat each args), separator: op.text + " ", minimumPrecedence: op.precedence)
        }
        else {
            sql.write((repeat each args), separator: " " + op.text + " ", minimumPrecedence: op.precedence)
        }
    }
}

public struct UnaryExpression<Value: SQLiteValue, Base: Expression>: Expression<Value> {
    public var op: SQLOperator
    public var base: Base
    
    @inlinable public init(op: SQLOperator, base: Base) {
        self.op = op
        self.base = base
    }
    
    @inlinable public var precedence: Int {
        op.precedence
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(" ")
        sql.write(op.text)
        sql.write(" ")
        sql.write(base, minimumPrecedence: op.precedence)
    }
}

public struct BetweenExpression<Base: Expression, Lower: Expression, Upper: Expression>: Expression<Bool> where Base.Value == Lower.Value, Base.Value == Upper.Value, Base.Value: Comparable {
    public var base: Base
    public var lower: Lower
    public var upper: Upper
    public var negated: Bool = false
    
    @inlinable public init(base: Base, lower: Lower, upper: Upper, negated: Bool = false) {
        self.base = base
        self.lower = lower
        self.upper = upper
        self.negated = negated
    }
    
    @inlinable public var precedence: Int {
        SQLOperator.equal.precedence
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(base, minimumPrecedence: SQLOperator.equal.precedence + 1)
        sql.write(negated ? " NOT BETWEEN " : " BETWEEN ")
        sql.write(lower, minimumPrecedence: SQLOperator.and.precedence + 1)
        sql.write(" AND ")
        sql.write(upper, minimumPrecedence: SQLOperator.and.precedence + 1)
    }

}

/// `x IN (?, ?, ?)` / `x NOT IN (…)` over a list of host values.
///
/// The list expands to one placeholder per value, so **the SQL text depends on the list's length**
/// and the statement cache keeps one statement per distinct length. For long lists of varying
/// length, or sets computed in the same database, use a subquery instead.
///
/// An empty list renders as `IN ()` (an SQLite extension): false for `IN`, true for `NOT IN`.
public struct InListExpression<Base: Expression>: Expression<Bool> where Base.Value: Equatable {
    public var base: Base

    /// Non-optional values: a `NULL` in the list would make `NOT IN` yield `NULL` for every row.
    public var list: [Base.Value.Base]
    public var negated: Bool = false
    
    @inlinable public init(base: Base, list: [Base.Value.Base], negated: Bool = false) {
        self.base = base
        self.list = list
        self.negated = negated
    }
    
    @inlinable public var precedence: Int {
        SQLOperator.equal.precedence
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(base, minimumPrecedence: SQLOperator.equal.precedence + 1)
        sql.write(negated ? " NOT IN (" : " IN (")

        for (i, value) in list.enumerated() {
            if i > 0 {
                sql.write(", ")
            }
            sql.write(parameter: value)
        }
        sql.write(")")
    }
}

/// `IS NULL` / `IS NOT NULL`.
///
/// Not restricted to optional values: after a `LEFT JOIN`, checking a non-optional column
/// for `NULL` is how "no matching row" is expressed.
public struct IsNullExpression<Base: Expression>: Expression<Bool> {
    public var base: Base
    public var negated: Bool = false
    
    @inlinable public init(base: Base, negated: Bool = false) {
        self.base = base
        self.negated = negated
    }
    
    @inlinable public var precedence: Int {
        SQLOperator.equal.precedence
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(base, minimumPrecedence: SQLOperator.equal.precedence + 1)
        sql.write(negated ? " IS NOT NULL" : " IS NULL")
    }
}

public struct CallExpression<Value: SQLiteValue, each Arguments: Expression>: Expression<Value> {
    public var call: String
    public var args: (repeat each Arguments)
    
    @inlinable public init(call: String, args: (repeat each Arguments)) {
        self.call = call
        self.args = args
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(call)
        sql.write("(")
        sql.write((repeat each args), separator: ", ")
        sql.write(")")
    }
}

public enum ConditionalExpression<Value: SQLiteValue, True: Expression<Value>, False: Expression<Value>>: Expression<Value> {
    case `true`(True)
    case `false`(False)
    
    @inlinable public var precedence: Int {
        switch self {
        case .true(let e): e.precedence
        case .false(let e): e.precedence
        }
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        switch self {
        case .true(let e): sql.write(e, minimumPrecedence: minimumPrecedence)
        case .false(let e): sql.write(e, minimumPrecedence: minimumPrecedence)
        }
    }

}

public struct RawExpression<Value: SQLiteValue>: Expression<Value> {
    public var raw: String
    
    @inlinable public init(raw: String) {
        self.raw = raw
    }
    
    @inlinable public func write(to sql: inout SQLWriter, minimumPrecedence: Int) {
        sql.write(raw)
    }

}

// MARK: - Equality

@inlinable public func == <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> where L.Value.Base == R.Value.Base {
    .init(op: .equal, left: lhs, right: rhs)
}

@inlinable public func == <V: SQLiteValue & Equatable, L: Expression<V>>(lhs: L, rhs: V) -> BinaryExpression<Bool, L, ParameterExpression<V>> {
    .init(op: .equal, left: lhs, right: .init(value: rhs))
}

@inlinable public func == <V: SQLiteValue & Equatable, L: Expression<V?>>(lhs: L, rhs: V?) -> ConditionalExpression<Bool, BinaryExpression<Bool, L, ParameterExpression<V?>>, IsNullExpression<L>> {
    if let rhs {
        return .true(lhs == rhs)
    }
    else {
        return .false(.init(base: lhs))
    }
}

@inlinable public func != <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> where L.Value.Base == R.Value.Base {
    .init(op: .notEqual, left: lhs, right: rhs)
}

@inlinable public func != <V: SQLiteValue & Equatable, L: Expression<V>>(lhs: L, rhs: V) -> BinaryExpression<Bool, L, ParameterExpression<V>> {
    .init(op: .notEqual, left: lhs, right: .init(value: rhs))
}

@inlinable public func != <V: SQLiteValue & Equatable, L: Expression<V?>>(lhs: L, rhs: V?) -> ConditionalExpression<Bool, BinaryExpression<Bool, L, ParameterExpression<V?>>, IsNullExpression<L>> {
    if let rhs {
        return .true(lhs != rhs)
    }
    else {
        return .false(.init(base: lhs, negated: true))
    }
}

// MARK: - Comparison

@inlinable public func < <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Comparable {
    .init(op: .less, left: lhs, right: rhs)
}

@inlinable public func <= <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Comparable {
    .init(op: .lessOrEqual, left: lhs, right: rhs)
}

@inlinable public func > <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Comparable {
    .init(op: .greater, left: lhs, right: rhs)
}

@inlinable public func >= <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Comparable {
    .init(op: .greaterOrEqual, left: lhs, right: rhs)
}

@inlinable public func < <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<Bool, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Comparable {
    .init(op: .less, left: lhs, right: .init(value: rhs))
}

@inlinable public func <= <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<Bool, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Comparable {
    .init(op: .lessOrEqual, left: lhs, right: .init(value: rhs))
}

@inlinable public func > <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<Bool, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Comparable {
    .init(op: .greater, left: lhs, right: .init(value: rhs))
}

@inlinable public func >= <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<Bool, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Comparable {
    .init(op: .greaterOrEqual, left: lhs, right: .init(value: rhs))
}

// MARK: - Arithmetic

@inlinable public func + <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<L.Value.Base, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Numeric {
    .init(op: .add, left: lhs, right: rhs)
}

@inlinable public func - <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<L.Value.Base, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Numeric {
    .init(op: .subtract, left: lhs, right: rhs)
}

@inlinable public func * <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<L.Value.Base, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Numeric {
    .init(op: .multiply, left: lhs, right: rhs)
}

@inlinable public func / <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<L.Value.Base, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Numeric {
    .init(op: .divide, left: lhs, right: rhs)
}

@inlinable public func % <L: Expression, R: Expression>(lhs: L, rhs: R) -> BinaryExpression<L.Value.Base, L, R> where L.Value.Base == R.Value.Base, L.Value.Base: Numeric {
    .init(op: .modulo, left: lhs, right: rhs)
}

@inlinable public func + <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<L.Value.Base, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Numeric {
    .init(op: .add, left: lhs, right: .init(value: rhs))
}

@inlinable public func - <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<L.Value.Base, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Numeric {
    .init(op: .subtract, left: lhs, right: .init(value: rhs))
}

@inlinable public func * <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<L.Value.Base, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Numeric {
    .init(op: .multiply, left: lhs, right: .init(value: rhs))
}

@inlinable public func / <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<L.Value.Base, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Numeric {
    .init(op: .divide, left: lhs, right: .init(value: rhs))
}

@inlinable public func % <L: Expression>(lhs: L, rhs: L.Value.Base) -> BinaryExpression<L.Value.Base, L, ParameterExpression<L.Value.Base>> where L.Value.Base: Numeric {
    .init(op: .modulo, left: lhs, right: .init(value: rhs))
}

// MARK: - Logic

@inlinable public func && <L: Expression<Bool>, R: Expression<Bool>>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> {
    .init(op: .and, left: lhs, right: rhs)
}

@inlinable public func || <L: Expression<Bool>, R: Expression<Bool>>(lhs: L, rhs: R) -> BinaryExpression<Bool, L, R> {
    .init(op: .or, left: lhs, right: rhs)
}

@inlinable public prefix func ! <L: Expression<Bool>>(_ base: L) -> UnaryExpression<Bool, L> {
    .init(op: .not, base: base)
}

// MARK: - Ranges and sets

extension Expression where Value: Comparable {
    @inlinable public func between(_ range: ClosedRange<Value>) -> BetweenExpression<Self, ParameterExpression<Value>, ParameterExpression<Value>> {
        .init(base: self, lower: .init(value: range.lowerBound), upper: .init(value: range.upperBound))
    }

    @inlinable public func notBetween(_ range: ClosedRange<Value>) -> BetweenExpression<Self, ParameterExpression<Value>, ParameterExpression<Value>> {
        .init(base: self, lower: .init(value: range.lowerBound), upper: .init(value: range.upperBound), negated: true)
    }
}

// MARK: - In list

extension Expression where Value: Equatable {
    /// `x IN (?, ?, …)` over host values; see `InListExpression`. An empty list matches nothing.
    @inlinable public func `in`(_ list: [Value.Base]) -> InListExpression<Self> {
        .init(base: self, list: list)
    }

    /// `x NOT IN (?, ?, …)`. An empty list matches everything.
    @inlinable public func notIn(_ list: [Value.Base]) -> InListExpression<Self> {
        .init(base: self, list: list, negated: true)
    }

}

// MARK: - NULL

extension Expression {
    /// `IS NULL`. After a `LEFT JOIN`, `NULL` in a joined column means no matching row.
    @inlinable public func isNull() -> IsNullExpression<Self> {
        .init(base: self)
    }

    /// `IS NOT NULL`.
    @inlinable public func isNotNull() -> IsNullExpression<Self> {
        .init(base: self, negated: true)
    }
}

// MARK: - Functions

extension Expression {
    @inlinable public func count() -> CallExpression<Int, Self> {
        .init(call: "COUNT", args: self)
    }
}

extension Expression where Value: Numeric {
    @inlinable public func abs() -> CallExpression<Value, Self> {
        .init(call: "ABS", args: self)
    }
}

extension Expression where Value.Base == String {
    @inlinable public func like(_ pattern: String) -> BinaryExpression<Bool, Self, ParameterExpression<String>> {
        .init(op: .like, left: self, right: .init(value: pattern))
    }
    
    @inlinable public func glob(_ pattern: String) -> BinaryExpression<Bool, Self, ParameterExpression<String>> {
        .init(op: .glob, left: self, right: .init(value: pattern))
    }
}

@inlinable public func min<E1: Expression, each E: Expression>(_ first: E1, _ rest: repeat each E) -> CallExpression<E1.Value, E1, repeat each E> {
    .init(call: "MIN", args: (first, repeat each rest))
}

@inlinable public func max<E1: Expression, each E: Expression>(_ first: E1, _ rest: repeat each E) -> CallExpression<E1.Value, E1, repeat each E> {
    .init(call: "MAX", args: (first, repeat each rest))
}

