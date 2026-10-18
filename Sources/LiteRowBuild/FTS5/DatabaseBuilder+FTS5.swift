//
//  DatabaseBuilder+FTS5.swift
//  LiteRowBuild
//

import LiteRow

// Build order for a full-text index ("data first, then indexes"):
//
//     create(tables) → insert(rows) → create(fts) → rebuild(fts) → optimize(fts)
//         → createIndexes(tables) → analyze() → vacuum(into:)
//
// `rebuild` before the content table is filled silently yields an empty index.

extension DatabaseBuilder {
    /// Moves the definition to `main`, as for regular tables.
    static func rebased(_ definition: FTS5Definition) -> FTS5Definition {
        var definition = definition
        definition.schemaName = DatabaseFile.main.schemaName
        return definition
    }

    /// `CREATE VIRTUAL TABLE … USING fts5(…)`, plus `pgsz` if set.
    ///
    /// The index starts empty: fill it with `rebuild(_:)` for external content or `insert(_:)` otherwise.
    public func create(_ definition: FTS5Definition) throws(LiteRowError) {
        let definition = Self.rebased(definition)
        try execute(definition.createTableSQL)
        // The page size only affects data written afterwards, so it is set right after creation.
        if let pageSizeSQL = definition.pageSizeSQL {
            try execute(pageSizeSQL)
        }
    }

    /// Creates an FTS5 table declared as a regular `@Table` model.
    public func create<T: Table>(
        fts table: T.Type,
        content: FTS5Definition.Content = .own,
        options: FTS5Definition.Options = FTS5Definition.Options(),
        unindexed: Set<String> = []
    ) throws(LiteRowError) {
        try create(FTS5Definition(table, content: content, options: options, unindexed: unindexed))
    }

    /// Creates an external-content index over a regular table; the text stays in `content`.
    ///
    /// Index columns must match content columns by name, and `rowID` must be an integer column.
    public func create<T: Table, C: Table, V: SQLiteValue>(
        fts table: T.Type,
        indexing content: C.Type,
        rowID: KeyPath<C.Columns, Column<C, V>>,
        options: FTS5Definition.Options = FTS5Definition.Options(),
        unindexed: Set<String> = []
    ) throws(LiteRowError) {
        try create(
            FTS5Definition(table, content: content, rowID: rowID, options: options, unindexed: unindexed)
        )
    }

    /// Rebuilds the index from its content table.
    ///
    /// Call **after** the content table is filled. Not available for `content=''`,
    /// which is filled by inserting rows.
    public func rebuild(_ definition: FTS5Definition) throws(LiteRowError) {
        precondition(
            definition.content != .contentless,
            "\(definition.tableName): rebuild reads the content table, and content='' has none. "
                + "Fill such an index by inserting rows."
        )
        try execute(Self.rebased(definition).rebuildSQL)
    }

    /// Merges the index b-trees into one; worthwhile for a database that never changes after the build.
    public func optimize(_ definition: FTS5Definition) throws(LiteRowError) {
        try execute(Self.rebased(definition).optimizeSQL)
    }
}
