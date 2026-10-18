//
//  RowDecodable.swift
//  LiteRow
//
//  Created by Artem Shimanski on 09.08.2026.
//

/// A type decoded from a contiguous range of columns in a result row.
///
/// Decoding starts at `offset`, and `width` tells the next type in a join where its columns begin.
public protocol RowDecodable: Sendable {
    /// Number of result columns the type occupies.
    static var width: Int32 { get }

    init(_ row: borrowing Row, offset: Int32) throws(LiteRowError)
}

extension RowDecodable {
    @inlinable
    public init(_ row: borrowing Row) throws(LiteRowError) {
        try self.init(row, offset: 0)
    }
}

/// A single value, e.g. the result of a one-column `select` or `count`.
public struct Scalar<Value: SQLiteValue>: RowDecodable {
    public let value: Value

    @inlinable public static var width: Int32 { 1 }

    @inlinable public init(_ row: borrowing Row, offset: Int32) throws(LiteRowError) {
        value = try Value(from: row, at: offset)
    }
}

/// The right side of a `LEFT JOIN`.
///
/// A `NULL` in the table's identity column means there is no matching row: a real row's key is never `NULL`.
extension Optional: RowDecodable where Wrapped: Table {
    @inlinable public static var width: Int32 { Wrapped.width }

    @inlinable public init(_ row: borrowing Row, offset: Int32) throws(LiteRowError) {
        if row.isNull(at: offset + Wrapped.identityColumn) {
            self = .none
        }
        else {
            self = .some(try Wrapped(row, offset: offset))
        }
    }
}

public struct Tuple<each Value: SQLiteValue>: RowDecodable {
    public var values: (repeat each Value)
    
    public static var width: Int32 {
        let n = countElements(repeat (each Value).self)
        return Int32(n)
    }
    
    public init(_ row: borrowing Row, offset: Int32) throws(LiteRowError) {
        var currentIndex = offset
        
        func decodeNext<T: SQLiteValue>(_ type: T.Type) throws(LiteRowError) -> T {
            let value = try T(from: row, at: currentIndex)
            currentIndex += 1
            return value
        }
        
        self.values = (repeat try decodeNext((each Value).self))
    }
}

@inlinable func countElements<each T>(_ item: repeat each T) -> Int {
    var count = 0
    for _ in repeat each item {
        count += 1
    }
    return count
}
