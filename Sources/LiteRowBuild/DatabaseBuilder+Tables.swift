//
//  DatabaseBuilder+Tables.swift
//  LiteRowBuild
//

import LiteRow

extension DatabaseBuilder {
    /// Moves the definition to `main`.
    ///
    /// A model's schema is a read-time default; the builder writes everything into the one
    /// file it opened.
    static func rebased(_ definition: TableDefinition) -> TableDefinition {
        var definition = definition
        definition.schemaName = DatabaseFile.main.schemaName
        return definition
    }

    /// Creates the model's table without indexes; call `createIndexes(_:)` **after** inserting data.
    public func create<T: Table>(
        _ table: T.Type,
        options: TableDefinition.Options = .default
    ) throws(LiteRowError) {
        try create(TableDefinition(table, options: options))
    }

    public func create(_ definition: TableDefinition) throws(LiteRowError) {
        try execute(Self.rebased(definition).createTableSQL)
    }

    /// Creates all of the model's `@Index` indexes.
    public func createIndexes<T: Table>(_ table: T.Type) throws(LiteRowError) {
        try createIndexes(TableDefinition(table))
    }

    public func createIndexes(_ definition: TableDefinition) throws(LiteRowError) {
        for sql in Self.rebased(definition).createIndexSQL {
            try execute(sql)
        }
    }

    /// Creates the table and fills it; indexes are left for `createIndexes(_:)`.
    public func create<T: Table & RowEncodable>(
        _ table: T.Type,
        filledWith rows: some Sequence<T>,
        options: TableDefinition.Options = .default
    ) throws(LiteRowError) {
        try create(table, options: options)
        try insert(rows)
    }
}

// MARK: - Insertion

extension DatabaseBuilder {
    /// Inserts rows in one transaction with one reused statement.
    ///
    /// Nested inside an outer `transaction { }`, it joins the outer transaction.
    public func insert<T: Table & RowEncodable>(_ rows: some Sequence<T>) throws(LiteRowError) {
        let definition = Self.rebased(TableDefinition(T.self))
        let statement = try prepared(definition.insertSQL)

        try begin()
        var isCommitted = false
        defer { if !isCommitted { rollback() } }

        for row in rows {
            var binder = Binder(statement: statement.handle.rawHandle)
            try row.bind(to: &binder)
            try statement.run()
        }

        try commit()
        isCommitted = true
    }

    public func insert<T: Table & RowEncodable>(_ row: T) throws(LiteRowError) {
        try insert(CollectionOfOne(row))
    }
}
