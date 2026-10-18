//
//  SchemaSQLTests.swift
//  LiteRowBuildTests
//

import Testing

import LiteRowBuild
@testable import LiteRow

// MARK: - Test models

/// An optional column: `NOT NULL` must not be set on it, or `nil` could no longer be inserted.
@Table("optionalRows")
struct OptionalRow {
    @PrimaryKey @Column("rowID") var id: UInt32
    var note: String?
    var weight: Double?
}

/// The key is not an integer: such a column cannot become a rowid alias.
@Table("textKeyed")
struct TextKeyed {
    @PrimaryKey var code: String
    var value: Int64
}

// MARK: - Metadata

@Suite("Column metadata")
struct ColumnMetadataTests {
    @Test("the descriptor carries the storage class")
    func storageClasses() {
        // Erasing `Column<Root, Value>` to a descriptor used to lose the type entirely,
        // so CREATE TABLE could not be built from it.
        #expect(TypeInfo.descriptor.columns.map(\.storageClass) == [.integer, .text, .integer])
        #expect(TypeAttribute.descriptor.columns.map(\.storageClass) == [.integer, .integer, .real])
    }

    @Test("column optionality is visible in the descriptor")
    func nullability() {
        #expect(OptionalRow.descriptor.columns.map(\.isNullable) == [false, true, true])
        #expect(TypeInfo.descriptor.columns.allSatisfy { !$0.isNullable })
    }

    @Test("a strongly typed key is stored as a number")
    func rawRepresentableStorage() {
        // `TypeID` wraps UInt32, so in the database it is INTEGER, nothing custom.
        #expect(TypeAttribute.columns.typeID.descriptor.storageClass == .integer)
    }
}


// MARK: - DDL

@Suite("CREATE TABLE")
struct CreateTableTests {
    @Test("a single integer key becomes a rowid alias")
    func rowIDAlias() {
        // `INTEGER PRIMARY KEY` is the rowid itself: the table gets no second b-tree,
        // and a key lookup becomes a rowid lookup.
        let sql = TableDefinition(TypeInfo.self).createTableSQL
        #expect(sql == """
            CREATE TABLE "main"."invTypes" (
                "typeID" INTEGER PRIMARY KEY NOT NULL,
                "typeName" TEXT NOT NULL,
                "groupID" INTEGER NOT NULL
            ) STRICT
            """)
    }

    @Test("a composite key goes into a table constraint")
    func compositeKey() {
        let sql = TableDefinition(TypeAttribute.self).createTableSQL
        #expect(sql == """
            CREATE TABLE "main"."dgmTypeAttributes" (
                "typeID" INTEGER NOT NULL,
                "attributeID" INTEGER NOT NULL,
                "value" REAL NOT NULL,
                PRIMARY KEY ("typeID", "attributeID")
            ) STRICT
            """)
    }

    @Test("a non-integer key does not become a rowid alias")
    func textKey() {
        // An inline `TEXT PRIMARY KEY` would be an ordinary unique index, not the rowid,
        // so it does not differ from the table constraint; both are written the same way.
        let sql = TableDefinition(TextKeyed.self).createTableSQL
        #expect(sql.contains(#"PRIMARY KEY ("code")"#))
        #expect(!sql.contains("TEXT PRIMARY KEY"))
    }

    @Test("WITHOUT ROWID cancels the rowid alias")
    func withoutRowID() {
        let sql = TableDefinition(TypeInfo.self, options: .keyOrdered).createTableSQL
        #expect(sql.hasSuffix(") STRICT, WITHOUT ROWID"))
        #expect(sql.contains(#"PRIMARY KEY ("typeID")"#))
        #expect(!sql.contains("INTEGER PRIMARY KEY"))
    }

    @Test("STRICT can be turned off")
    func nonStrict() {
        let sql = TableDefinition(TypeInfo.self, options: .init(isStrict: false)).createTableSQL
        #expect(sql.hasSuffix(")"))
        #expect(!sql.contains("STRICT"))
    }

    @Test("an optional column is declared without NOT NULL")
    func nullableColumns() {
        let sql = TableDefinition(OptionalRow.self).createTableSQL
        #expect(sql.contains(#""note" TEXT,"#))
        #expect(sql.contains(#""weight" REAL"#))
        #expect(!sql.contains("TEXT NOT NULL"))
    }

    @Test("the schema goes into the table name")
    func schemaQualified() {
        // An attached schema: the same model as in the read tests.
        #expect(TableDefinition(AuxIconForBuild.self).createTableSQL.hasPrefix(#"CREATE TABLE "aux"."eveIcons""#))
    }
}

extension DatabaseFile {
    static let aux = DatabaseFile(schemaName: "aux")
}

/// A table in an attached schema.
@Table("eveIcons", schema: .aux)
struct AuxIconForBuild {
    @PrimaryKey @Column("iconID") var id: UInt32
    @Column("iconFile") var path: String
}

@Suite("CREATE INDEX")
struct CreateIndexTests {
    @Test("an index from the @Index mark")
    func markedIndex() {
        let sql = TableDefinition(TypeInfo.self).createIndexSQL
        #expect(sql == [
            #"CREATE INDEX "main"."idx_invTypes_groupID" ON "invTypes" ("groupID")"#
        ])
    }

    @Test("a hand-written composite index keeps the sort order")
    func customIndex() {
        let sql = TableDefinition(TypeAttribute.self).createIndexSQL
        // ASC is not written: it is the default, and the text only gets longer.
        #expect(sql == [
            #"CREATE INDEX "main"."dgmTypeAttributes_byAttributeValue" ON "dgmTypeAttributes" ("attributeID", "value" DESC)"#
        ])
    }

    @Test("a table without indexes produces no CREATE INDEX")
    func noIndexes() {
        #expect(TableDefinition(OptionalRow.self).createIndexSQL.isEmpty)
    }
}

@Suite("INSERT")
struct InsertSQLTests {
    @Test("columns are listed explicitly and in projection order")
    func columnOrder() {
        // The same order as SELECT: decoding offsets and positional parameter binding depend on it.
        #expect(
            TableDefinition(TypeInfo.self).insertSQL
                == #"INSERT INTO "main"."invTypes" ("typeID", "typeName", "groupID") VALUES (?, ?, ?)"#
        )
    }

    @Test("there are exactly as many parameters as columns")
    func placeholderCount() {
        let definition = TableDefinition(TypeAttribute.self)
        #expect(definition.insertSQL.filter { $0 == "?" }.count == definition.columns.count)
    }
}
