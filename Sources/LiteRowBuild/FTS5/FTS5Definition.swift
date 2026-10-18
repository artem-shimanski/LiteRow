//
//  FTS5Definition.swift
//  LiteRowBuild
//

@_spi(Build) import LiteRow

/// An FTS5 table description, enough for `CREATE VIRTUAL TABLE`.
///
/// The FTS5 table is declared as a regular `@Table` model; column order is property order.
public struct FTS5Definition: Sendable, Hashable {
    public var schemaName: String
    public var tableName: String
    /// Columns in declaration order; it defines column numbers for `snippet`/`highlight`
    /// and the order of `bm25` weights.
    public var columns: [Column]
    public var content: Content
    public var options: Options

    public init(
        schemaName: String,
        tableName: String,
        columns: [Column],
        content: Content = .own,
        options: Options = Options()
    ) {
        self.schemaName = schemaName
        self.tableName = tableName
        self.columns = columns
        self.content = content
        self.options = options
    }
}

extension FTS5Definition {
    /// A virtual table column (FTS5 columns have no type).
    public struct Column: Sendable, Hashable {
        public let name: String
        /// `false` stores the column without indexing it (`UNINDEXED`).
        public let isIndexed: Bool

        public init(name: String, isIndexed: Bool = true) {
            self.name = name
            self.isIndexed = isIndexed
        }
    }

    /// Where FTS5 takes the source text from.
    public enum Content: Sendable, Hashable {
        /// The virtual table stores its own copy of the text; filled with `insert`.
        case own

        /// `content=''`: only the index is stored.
        ///
        /// Columns read as `NULL`, `snippet`/`highlight` return nothing, and the table must be
        /// filled row by row (`rebuild` is not available).
        case contentless

        /// `content='invTypes', content_rowid='typeID'`: the text stays in a regular table.
        ///
        /// Filled with one `rebuild` after the content table is filled. `rowID` must be a rowid
        /// alias (`INTEGER PRIMARY KEY`), so `WITHOUT ROWID` content tables are not supported.
        case external(table: String, rowID: String)
    }

    public struct Options: Sendable, Hashable {
        public var tokenizer: Tokenizer
        /// Prefix index lengths: `[2, 3]` gives `prefix='2 3'`. Speeds up prefix queries like `"rif"*`.
        public var prefixes: [Int]
        public var detail: Detail
        /// `pgsz`: the index page size, applied right after the table is created.
        public var pageSize: Int?

        public init(
            tokenizer: Tokenizer = .unicode61(),
            prefixes: [Int] = [],
            detail: Detail = .full,
            pageSize: Int? = nil
        ) {
            self.tokenizer = tokenizer
            self.prefixes = prefixes
            self.detail = detail
            self.pageSize = pageSize
        }

        /// Search-as-you-type: diacritics removed, prefixes of 2 and 3 indexed.
        public static let asYouType = Options(
            tokenizer: .unicode61(removeDiacritics: .full),
            prefixes: [2, 3]
        )

        /// Substring search anywhere in a word, using the `trigram` tokenizer.
        public static let substring = Options(tokenizer: .trigram())
    }

    /// `detail=`: how much positional information the index stores.
    public enum Detail: String, Sendable, Hashable {
        /// Rowid, column and position; required for phrases, `NEAR` and good snippets.
        case full
        /// No positions within a column: phrases and `NEAR` do not work.
        case column
        /// Rowid only: no column filters and no phrases. The most compact index.
        case none
    }
}

// MARK: - Tokenizer

extension FTS5Definition {
    /// A tokenizer with its arguments, as one FTS5 specification string.
    public struct Tokenizer: Sendable, Hashable {
        public let specification: String

        /// A raw specification, e.g. for a custom registered tokenizer.
        public init(unsafe specification: String) {
            self.specification = specification
        }

        /// Diacritics handling in `unicode61`.
        public enum Diacritics: Int, Sendable, Hashable {
            /// `é` and `e` are different tokens.
            case keep = 0
            /// Removed from some Latin characters only (legacy mode).
            case latin = 1
            /// Removed wherever Unicode defines a decomposition.
            case full = 2
        }

        /// The default tokenizer: letters and digits form tokens, everything else separates them.
        public static func unicode61(
            removeDiacritics: Diacritics = .full,
            tokenCharacters: String? = nil,
            separators: String? = nil
        ) -> Tokenizer {
            var parts = ["unicode61", "remove_diacritics \(removeDiacritics.rawValue)"]
            if let tokenCharacters {
                parts.append("tokenchars \(tokenCharacters.quotedStringLiteral)")
            }
            if let separators {
                parts.append("separators \(separators.quotedStringLiteral)")
            }
            return Tokenizer(unsafe: parts.joined(separator: " "))
        }

        /// Treats every non-ASCII character as a token character.
        public static let ascii = Tokenizer(unsafe: "ascii")

        /// Porter stemming on top of another tokenizer: `ships` and `ship` become one token.
        public static func porter(_ base: Tokenizer? = nil) -> Tokenizer {
            guard let base else { return Tokenizer(unsafe: "porter") }
            return Tokenizer(unsafe: "porter \(base.specification)")
        }

        /// Every three consecutive characters form a token, enabling substring search and
        /// indexed `LIKE '%…%'` (the latter not with diacritics removal).
        public static func trigram(
            caseSensitive: Bool = false,
            removeDiacritics: Bool = false
        ) -> Tokenizer {
            precondition(
                !(caseSensitive && removeDiacritics),
                "trigram: remove_diacritics is incompatible with case_sensitive; FTS5 would reject the table."
            )
            var parts = ["trigram"]
            if caseSensitive { parts.append("case_sensitive 1") }
            if removeDiacritics { parts.append("remove_diacritics 1") }
            return Tokenizer(unsafe: parts.joined(separator: " "))
        }
    }
}

// MARK: - From a model

extension FTS5Definition {
    /// Builds the description from a regular `@Table` model.
    ///
    /// The model must have no `@PrimaryKey` or `@Index`, and its indexed columns must be text.
    public init<T: Table>(
        _ table: T.Type,
        content: Content = .own,
        options: Options = Options(),
        unindexed: Set<String> = []
    ) {
        let descriptor = T.descriptor
        precondition(
            !descriptor.columns.isEmpty,
            "FTS5 table \(T.tableName) has no columns."
        )
        precondition(
            descriptor.primaryKey.isEmpty,
            "\(T.tableName): an FTS5 table has no primary key; rows are addressed by rowid. "
                + "Remove @PrimaryKey; content_rowid links it to the content table."
        )
        precondition(
            descriptor.indexes.isEmpty,
            "\(T.tableName): CREATE INDEX on a virtual table is not possible. "
                + "Remove @Index; the table itself is the index."
        )
        let unknown = unindexed.subtracting(descriptor.columns.map(\.name))
        precondition(
            unknown.isEmpty,
            "\(T.tableName): unindexed lists columns that are not in the model: "
                + unknown.sorted().joined(separator: ", ")
        )

        let columns = descriptor.columns.map { column in
            let isIndexed = !unindexed.contains(column.name)
            precondition(
                !isIndexed || column.storageClass == .text,
                "\(T.tableName).\(column.name): an indexed FTS5 column must be text. "
                    + "Declare non-text values UNINDEXED."
            )
            return Column(name: column.name, isIndexed: isIndexed)
        }

        self.init(
            schemaName: T.schemaName,
            tableName: T.tableName,
            columns: columns,
            content: content,
            options: options
        )
    }

    /// An external-content index over a regular table; the text stays in `content`.
    ///
    /// Index columns must match content columns by name, and `rowID` must be an integer column.
    public init<T: Table, C: Table, V: SQLiteValue>(
        _ table: T.Type,
        content: C.Type,
        rowID: KeyPath<C.Columns, LiteRow.Column<C, V>>,
        options: Options = Options(),
        unindexed: Set<String> = []
    ) {
        let key = C.columns[keyPath: rowID]
        precondition(
            V.storageClass == .integer,
            "\(C.tableName).\(key.name) is not an integer: content_rowid must be a rowid alias."
        )
        let contentColumns = Set(C.descriptor.columns.map(\.name))
        let missing = Set(T.descriptor.columns.map(\.name)).subtracting(contentColumns)
        precondition(
            missing.isEmpty,
            "\(T.tableName): columns \(missing.sorted().joined(separator: ", ")) are missing from the content "
                + "table \(C.tableName); FTS5 matches columns by name."
        )
        self.init(
            table,
            content: .external(table: C.tableName, rowID: key.name),
            options: options,
            unindexed: unindexed
        )
    }
}

// MARK: - DDL

extension FTS5Definition {
    /// The qualified table name, e.g. `"main"."invTypes_fts"`.
    public var qualifiedName: String {
        "\(schemaName.quotedIdentifier).\(tableName.quotedIdentifier)"
    }

    /// `CREATE VIRTUAL TABLE … USING fts5(…)`.
    ///
    /// Option values are written as quoted string literals.
    public var createTableSQL: String {
        precondition(
            !columns.isEmpty,
            "FTS5 table \(tableName) has no columns."
        )
        precondition(
            columns.contains(where: \.isIndexed),
            "FTS5 table \(tableName): all columns are UNINDEXED, nothing to search."
        )

        var arguments = columns.map { column in
            column.isIndexed
                ? "    \(column.name.quotedIdentifier)"
                : "    \(column.name.quotedIdentifier) UNINDEXED"
        }

        arguments.append("    tokenize = \(options.tokenizer.specification.quotedStringLiteral)")

        if !options.prefixes.isEmpty {
            precondition(
                options.prefixes.allSatisfy { $0 > 0 },
                "\(tableName): prefix length must be positive."
            )
            let prefixes = options.prefixes.map(String.init).joined(separator: " ")
            arguments.append("    prefix = \(prefixes.quotedStringLiteral)")
        }

        switch content {
        case .own:
            break
        case .contentless:
            arguments.append("    content = ''")
        case let .external(table, rowID):
            arguments.append("    content = \(table.quotedStringLiteral)")
            arguments.append("    content_rowid = \(rowID.quotedStringLiteral)")
        }

        // Written as a bare keyword, as in the FTS5 documentation.
        if options.detail != .full {
            arguments.append("    detail = \(options.detail.rawValue)")
        }

        return "CREATE VIRTUAL TABLE \(qualifiedName) USING fts5(\n"
            + arguments.joined(separator: ",\n")
            + "\n)"
    }

    /// An FTS5 command: `INSERT INTO ft(ft) VALUES('…')`; the table name appears as both the
    /// table (schema-qualified) and its hidden column.
    private func commandSQL(_ command: String) -> String {
        "INSERT INTO \(qualifiedName)(\(tableName.quotedIdentifier)) VALUES(\(command.quotedStringLiteral))"
    }

    /// Rebuilds the index from its content table. Not available for `content=''`.
    public var rebuildSQL: String { commandSQL("rebuild") }

    /// Merges all index b-trees into one; run last, after the index is filled.
    public var optimizeSQL: String { commandSQL("optimize") }

    /// `pgsz`: the index page size; affects data written afterwards.
    public var pageSizeSQL: String? {
        guard let pageSize = options.pageSize else { return nil }
        precondition(pageSize > 0, "\(tableName): pgsz must be positive.")
        return "INSERT INTO \(qualifiedName)(\(tableName.quotedIdentifier), \("rank".quotedIdentifier)) "
            + "VALUES(\("pgsz".quotedStringLiteral), \(pageSize))"
    }
}
