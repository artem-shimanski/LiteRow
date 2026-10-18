//
//  TableIndex.swift
//  LiteRow
//

/// A column within an index. `Root` keeps columns of other tables out.
public struct IndexColumn<Root: Table>: Sendable, Hashable {
    public let name: String
    public let direction: Order
    /// The collation name (`NOCASE`, `BINARY`, …); `nil` uses the column's collation.
    public let collation: String?

    public init(name: String, direction: Order = .ascending, collation: String? = nil) {
        self.name = name
        self.direction = direction
        self.collation = collation
    }
}

extension IndexColumn {
    /// An index column from a column value: `.column(Self.columns.typeID)`.
    @inlinable
    public static func column<Value: SQLiteValue>(
        _ column: Column<Root, Value>,
        _ direction: Order = .ascending,
        collate collation: String? = nil
    ) -> IndexColumn {
        IndexColumn(name: column.name, direction: direction, collation: collation)
    }

    /// An index column from a key path: `.column(\.typeID)`.
    @inlinable
    public static func column<Value: SQLiteValue>(
        _ keyPath: KeyPath<Root.Columns, Column<Root, Value>>,
        _ direction: Order = .ascending,
        collate collation: String? = nil
    ) -> IndexColumn {
        IndexColumn(
            name: Root.columns[keyPath: keyPath].name,
            direction: direction,
            collation: collation
        )
    }
}

/// A partial index condition on one column.
///
/// SQLite uses a partial index only if the query's predicate provably implies the index's:
///
/// - `IS NOT NULL` is implied by any comparison of the column (`col = ?`, `col > ?`, …).
/// - A flag is matched only textually: an index `WHERE "flag"` is used by `filter { $0.flag }`,
///   but not by `filter { $0.flag == true }` (which binds a parameter). Likewise `.isFalse`
///   and `filter { !$0.flag }`.
public enum IndexCondition: String, Sendable, Hashable {
    case notNull
    case null
    case isTrue
    case isFalse
}

/// A partial index condition together with its column, filled in by `@Index(where:)` or `@IndexFilter`.
public struct IndexPredicate: Sendable, Hashable {
    /// The unquoted column name.
    public let column: String
    public let condition: IndexCondition

    public init(column: String, condition: IndexCondition) {
        self.column = column
        self.condition = condition
    }
}

/// A table index description (metadata only; `LiteRowBuild` creates the index).
///
/// Declared with `@Index` on properties: one attribute is a single-column index, several
/// attributes with the same name form one composite index in property order.
public struct TableIndex<Root: Table>: Sendable, Hashable {
    /// An explicit name; `nil` derives one from the table and column names (`resolvedName`).
    public let name: String?
    public let columns: [IndexColumn<Root>]
    public let isUnique: Bool

    /// Partial index conditions, joined with `AND` in property order; empty for a full index.
    public let predicates: [IndexPredicate]

    public init(
        name: String? = nil,
        columns: [IndexColumn<Root>],
        unique: Bool = false,
        predicates: [IndexPredicate] = []
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = unique
        self.predicates = predicates
    }

    public init(_ columns: IndexColumn<Root>..., unique: Bool = false) {
        self.init(name: nil, columns: columns, unique: unique)
    }

    public init(name: String, _ columns: IndexColumn<Root>..., unique: Bool = false) {
        self.init(name: name, columns: columns, unique: unique)
    }
}

extension TableIndex {
    /// The explicit name, or one built from the table and column names (index names are schema-global).
    @inlinable public var resolvedName: String {
        if let name { return name }
        return (["idx", Root.tableName] + columns.map(\.name)).joined(separator: "_")
    }
}
