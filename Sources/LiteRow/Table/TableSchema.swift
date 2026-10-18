//
//  TableSchema.swift
//  LiteRow
//
//  Created by Artem Shimanski on 10.08.2026.
//

import Synchronization

/// A column description, type-erased to its name, position and storage class.
///
/// `index` is relative to the column's own table, not a position in the statement; the
/// table's offset in the projection is added at runtime.
public struct ColumnDescriptor: Sendable, Hashable {
    public let name: String

    /// The name quoted for SQL, computed once.
    public let quotedName: String

    public let index: Int32
    public let storageClass: StorageClass
    /// The value type is optional, so the column is declared without `NOT NULL`.
    public let isNullable: Bool

    public init(name: String, index: Int32, storageClass: StorageClass, isNullable: Bool) {
        self.name = name
        self.quotedName = name.quotedIdentifier
        self.index = index
        self.storageClass = storageClass
        self.isNullable = isNullable
    }
}

/// A typed column. Its alias and position in a query come from the `TableRef` it is accessed through.
public struct Column<Root: Table, Value: SQLiteValue>: Sendable, Hashable {
    public let name: String

    /// The name quoted for SQL, computed once rather than on every write.
    public let quotedName: String
    public let index: Int32

    public init(name: String, index: Int32) {
        self.name = name
        self.quotedName = name.quotedIdentifier
        self.index = index
    }

    /// The type-erased descriptor, with storage class and nullability taken from `Value`.
    @inlinable public var descriptor: ColumnDescriptor {
        ColumnDescriptor(
            name: name,
            index: index,
            storageClass: Value.storageClass,
            isNullable: Value.isNullable
        )
    }

    /// Reads the column's value, given the table's offset in the projection.
    @inlinable public func decode(from row: borrowing Row, offset: Int32) throws(LiteRowError) -> Value {
        try Value(from: row, at: offset + index)
    }

    /// Reads the value at an absolute position, ignoring the table layout (e.g. key-only projections).
    @inlinable public func decode(from row: borrowing Row, at column: Int32) throws(LiteRowError) -> Value {
        try Value(from: row, at: column)
    }
}
