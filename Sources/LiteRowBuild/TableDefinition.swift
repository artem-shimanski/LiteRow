//
//  TableDefinition.swift
//  LiteRowBuild
//

import LiteRow

/// An index column, type-erased to its name.
public struct IndexColumnDefinition: Sendable, Hashable {
    public let name: String
    public let direction: Order
    public let collation: String?

    public init(name: String, direction: Order = .ascending, collation: String? = nil) {
        self.name = name
        self.direction = direction
        self.collation = collation
    }
}

/// An index with its name resolved.
public struct IndexDefinition: Sendable, Hashable {
    /// The name used in `CREATE INDEX`: given in `@Index` or derived from the table name.
    public let name: String
    public let columns: [IndexColumnDefinition]
    public let isUnique: Bool
    /// Partial index conditions; empty for an index over all rows.
    public let predicates: [IndexPredicate]

    public init(
        name: String,
        columns: [IndexColumnDefinition],
        isUnique: Bool = false,
        predicates: [IndexPredicate] = []
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.predicates = predicates
    }

    /// Erases a `TableIndex<Root>`, resolving its name while `Root` is known.
    public init<Root: Table>(_ index: TableIndex<Root>) {
        self.init(
            name: index.resolvedName,
            columns: index.columns.map {
                IndexColumnDefinition(name: $0.name, direction: $0.direction, collation: $0.collation)
            },
            isUnique: index.isUnique,
            predicates: index.predicates
        )
    }
}

/// A type-erased table description, enough for `CREATE TABLE` and `CREATE INDEX`.
///
/// Usually built from a model with `init(_:options:)`.
public struct TableDefinition: Sendable, Hashable {
    public var schemaName: String
    public var tableName: String
    /// Columns in projection order, the same order `INSERT` and `SELECT` use.
    public var columns: [ColumnDescriptor]
    /// Primary key columns in declaration order; empty for a table without a key.
    public var primaryKeyColumns: [ColumnDescriptor]
    public var indexes: [IndexDefinition]
    public var options: Options

    public init(
        schemaName: String,
        tableName: String,
        columns: [ColumnDescriptor],
        primaryKeyColumns: [ColumnDescriptor] = [],
        indexes: [IndexDefinition] = [],
        options: Options = .default
    ) {
        self.schemaName = schemaName
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.indexes = indexes
        self.options = options
    }
}

extension TableDefinition {
    public struct Options: Sendable, Hashable {
        /// `STRICT`: SQLite rejects values that do not match the declared column type. On by default.
        public var isStrict: Bool

        /// `WITHOUT ROWID`: the table is stored in its primary key b-tree. Requires a primary key.
        public var isWithoutRowID: Bool

        public init(isStrict: Bool = true, isWithoutRowID: Bool = false) {
            self.isStrict = isStrict
            self.isWithoutRowID = isWithoutRowID
        }

        public static let `default` = Options()
        /// For tables with a composite key that are always read by key.
        public static let keyOrdered = Options(isWithoutRowID: true)
    }
}

extension TableDefinition {
    /// Builds the description from a model's `descriptor`.
    public init<T: Table>(_ table: T.Type, options: Options = .default) {
        self.init(
            schemaName: T.schemaName,
            tableName: T.tableName,
            columns: T.descriptor.columns,
            primaryKeyColumns: T.descriptor.primaryKey,

            indexes: T.descriptor.indexes.map { IndexDefinition($0) },
            options: options
        )
    }
}
