//
//  SchemaSQL.swift
//  LiteRowBuild
//

@_spi(Build) import LiteRow

// DDL and `INSERT` generation: pure functions of the table definition, no connection needed.
// Identifiers are quoted with the same `quotedIdentifier` the read side uses.

extension TableDefinition {
    /// The qualified table name, e.g. `"main"."invTypes"`.
    public var qualifiedName: String {
        "\(schemaName.quotedIdentifier).\(tableName.quotedIdentifier)"
    }

    /// The single integer key column that can be declared as a rowid alias (`INTEGER PRIMARY KEY`).
    ///
    /// Only for a one-column `INTEGER` key in a rowid table.
    var rowIDAliasColumn: ColumnDescriptor? {
        guard !options.isWithoutRowID,
              primaryKeyColumns.count == 1,
              let key = primaryKeyColumns.first,
              key.storageClass == .integer
        else { return nil }
        return key
    }

    public var createTableSQL: String {
        precondition(
            !columns.isEmpty,
            "Table \(tableName) has no columns."
        )
        precondition(
            !options.isWithoutRowID || !primaryKeyColumns.isEmpty,
            "WITHOUT ROWID requires a primary key, and \(tableName) has none."
        )

        let alias = rowIDAliasColumn
        var lines: [String] = []

        for column in columns {
            var definition = "    \(column.name.quotedIdentifier) \(column.storageClass.rawValue)"
            if column == alias {
                definition += " PRIMARY KEY"
            }
            if !column.isNullable {
                definition += " NOT NULL"
            }
            lines.append(definition)
        }

        // Table-level key: composite, non-integer, or WITHOUT ROWID.
        if alias == nil, !primaryKeyColumns.isEmpty {
            let keys = primaryKeyColumns.map { $0.name.quotedIdentifier }.joined(separator: ", ")
            lines.append("    PRIMARY KEY (\(keys))")
        }

        var suffix: [String] = []
        if options.isStrict { suffix.append("STRICT") }
        if options.isWithoutRowID { suffix.append("WITHOUT ROWID") }
        let tail = suffix.isEmpty ? "" : " \(suffix.joined(separator: ", "))"

        // Stored verbatim in `sqlite_master`; one column per line keeps it readable.
        return "CREATE TABLE \(qualifiedName) (\n\(lines.joined(separator: ",\n"))\n)\(tail)"
    }

    /// One `CREATE INDEX` per index, in `Table.descriptor.indexes` order.
    public var createIndexSQL: [String] {
        indexes.map { index in
            let columns = index.columns.map { column -> String in
                var text = column.name.quotedIdentifier
                if let collation = column.collation {
                    text += " COLLATE \(collation.quotedIdentifier)"
                }

                if column.direction == .descending {
                    text += " DESC"
                }
                return text
            }
            // The index name is schema-qualified; the table after `ON` must not be.
            let unique = index.isUnique ? "UNIQUE " : ""
            return "CREATE \(unique)INDEX \(schemaName.quotedIdentifier).\(index.name.quotedIdentifier)"
                + " ON \(tableName.quotedIdentifier) (\(columns.joined(separator: ", ")))"
                + index.whereClause
        }
    }

    /// `INSERT` of all columns in projection order, with the column list spelled out.
    public var insertSQL: String {
        let names = columns.map { $0.name.quotedIdentifier }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return "INSERT INTO \(qualifiedName) (\(names)) VALUES (\(placeholders))"
    }
}

extension IndexDefinition {
    /// The partial index tail: ` WHERE …`, or an empty string.
    ///
    /// The condition must have the same form the query writes: the planner uses a partial index
    /// only if the query's predicate implies the index's, and it does not equate `"flag"` with
    /// `"flag" = 1`.
    var whereClause: String {
        guard !predicates.isEmpty else { return "" }
        let terms = predicates.map { predicate -> String in
            let column = predicate.column.quotedIdentifier
            return switch predicate.condition {
            case .notNull: "\(column) IS NOT NULL"
            case .null: "\(column) IS NULL"
            case .isTrue: column
            case .isFalse: "NOT \(column)"
            }
        }
        return " WHERE \(terms.joined(separator: " AND "))"
    }
}
