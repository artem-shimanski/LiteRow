//
//  Join.swift
//  LiteRow
//
//  Created by Artem Shimanski on 10.08.2026.
//

/// The result of joining two relations.
///
/// Higher arity is expressed by nesting: `Join<Join<A, B>, C>`. Column offsets are computed
/// statically. `LEFT JOIN` yields `Join<A, B?>` via `Optional: RowDecodable`.
public struct Join<Left: RowDecodable, Right: RowDecodable>: RowDecodable {
    public let left: Left
    public let right: Right

    @inlinable public static var width: Int32 { Left.width + Right.width }

    @inlinable public init(left: Left, right: Right) {
        self.left = left
        self.right = right
    }

    @inlinable public init(_ row: borrowing Row, offset: Int32) throws(LiteRowError) {
        left = try Left(row, offset: offset)
        right = try Right(row, offset: offset + Left.width)
    }
}

extension Join: Equatable where Left: Equatable, Right: Equatable {}
extension Join: Hashable where Left: Hashable, Right: Hashable {}

extension Join {
    @inlinable public var tuple: (Left, Right) {
        (left, right)
    }

    @inlinable public func map<T>(_ transform: (Left, Right) throws -> T) rethrows -> T {
        try transform(left, right)
    }
}

extension Join {
    /// Flattens `Join<Join<A, B>, C>` into `(A, B, C)`.
    @inlinable public func flattened<A: RowDecodable, B: RowDecodable>() -> (A, B, Right) where Left == Join<A, B> {
        (left.left, left.right, right)
    }

    /// Flattens `Join<Join<Join<A, B>, C>, D>` into `(A, B, C, D)`.
    @inlinable public func flattened<A: RowDecodable, B: RowDecodable, C: RowDecodable>() -> (A, B, C, Right)
    where Left == Join<Join<A, B>, C> {
        (left.left.left, left.left.right, left.right, right)
    }
}
