//
//  TableMacroTests.swift
//  LiteRowTests
//

import Testing
@testable import LiteRow

// MARK: - Test models

/// The schema for read tests as a single value, referenced by both `@Table` and `attached`
/// on `Database`, so the names cannot drift apart.
extension DatabaseFile {
    static let aux = DatabaseFile(schemaName: "aux")
}

/// A table in an attached schema: the macro takes the same value that is the key in `attached`
/// on `Database`.
@Table("eveIcons", schema: .aux)
struct AuxIcon {
    @Column("iconID") var id: UInt32
    var typeID: UInt32
    @Column("iconFile") var path: String
}

/// The anchor column is not the first one: `NULL` in it identifies a `LEFT JOIN` miss.
@Table("invTypes")
struct TypeWithExplicitIdentity {
    @Column("typeName") var name: String
    @Column("typeID", identity: true) var id: UInt32
    var groupID: UInt32
}

/// A `let` with a default value is not a column; it declares a field the table does not have.
/// Computed properties are skipped too.
@Table("invGroups")
struct GroupWithExtras {
    @Column("groupID") var id: UInt32
    @Column("groupName") var name: String
    var categoryID: UInt32

    let source: String = "static"
    var isShip: Bool { categoryID == 6 }
}

// MARK: - Tests

@Suite("@Table macro")
struct TableMacroTests {
    @Test("column names come from @Column, otherwise from the property name")
    func columnNames() {
        #expect(AuxIcon.columns.id.name == "iconID")
        #expect(AuxIcon.columns.typeID.name == "typeID")
        #expect(AuxIcon.columns.path.name == "iconFile")
    }

    @Test("indexes follow property order")
    func columnIndices() {
        #expect(AuxIcon.columns.id.index == 0)
        #expect(AuxIcon.columns.typeID.index == 1)
        #expect(AuxIcon.columns.path.index == 2)
        #expect(AuxIcon.descriptor.columns.map(\.index) == [0, 1, 2])
        #expect(AuxIcon.width == 3)
    }

    @Test("order in columns matches order in Columns")
    func projectionOrder() {
        #expect(AuxIcon.descriptor.columns.map(\.name) == ["iconID", "typeID", "iconFile"])
    }

    @Test("table and schema names come from the attribute")
    func names() {
        #expect(AuxIcon.tableName == "eveIcons")
        #expect(AuxIcon.schema == .aux)
        #expect(AuxIcon.schemaName == "aux")
        #expect(TypeInfo.tableName == "invTypes")
        // Without an argument the schema stays at the protocol default.
        #expect(TypeInfo.schema == .main)
        #expect(TypeInfo.schemaName == "main")
    }

    @Test("the anchor column is set explicitly")
    func identityColumn() {
        #expect(TypeWithExplicitIdentity.identityColumn == 1)
        // Without the mark the protocol default stays: the first column.
        #expect(AuxIcon.identityColumn == 0)
    }

    @Test("non-stored properties do not become columns")
    func skipsNonStoredProperties() {
        #expect(GroupWithExtras.descriptor.columns.map(\.name) == ["groupID", "groupName", "categoryID"])
    }

    @Test("the generated projection appears in SQL in the right order")
    func rendersProjection() {
        let sql = AuxIcon.all().query().sql
        #expect(sql == #"SELECT * FROM "aux"."eveIcons" AS t0"#)
    }

    @Test("a macro-generated model decodes from the database")
    func decodesRows() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let row = try await database.read { reader in
            try reader.fetchOne(TypeInfo.all().filter { $0.id == UInt32(3) }.query())
        }

        #expect(row?.id == 3)
        #expect(row?.name == "Raven")
        #expect(row?.groupID == 27)
        withExtendedLifetime(fixture) {}
    }

    @Test("join offsets are computed from the width of the left model")
    func decodesJoinedRows() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let rows = try await database.read { reader -> [String] in
            let query = TypeInfo.all()
                .join(TypeGroup.self) { type, group in type.groupID == group.id }
                .order(by: { type, _ in type.id })
                .query()
            return try reader.fetchAll(query).map { "\($0.left.name)/\($0.right.name)" }
        }

        #expect(rows == ["Rifter/Frigate", "Punisher/Frigate", "Raven/Battleship"])
        withExtendedLifetime(fixture) {}
    }

    @Test("a LEFT JOIN miss is detected by the anchor column")
    func decodesMissingLeftJoinSide() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)
        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: icons.name)]
        )

        let rows = try await database.read { reader -> [String] in
            let query = TypeInfo.all()
                .leftJoin(AuxIcon.self) { type, icon in icon.typeID == type.id }
                .order(by: { type, _ in type.id })
                .query()
            return try reader.fetchAll(query).map { "\($0.left.name)/\($0.right?.path ?? "-")" }
        }

        #expect(rows == ["Rifter/rifter.png", "Punisher/-", "Raven/raven.png"])
        withExtendedLifetime((main, icons)) {}
    }
}


// MARK: - Partial indexes

/// A condition on its own column, a condition on another column and a renamed column, all at once.
///
/// The rename matters: the source never spells the column name, the mark is on the property,
/// so the macro must resolve the name. If it took the property name instead of the column name,
/// `CREATE INDEX` would fail with `no such column`.
@Table("partialMacroRows")
struct PartialMacroRow {
    @PrimaryKey @Index("byFlag") var id: UInt32
    @Column("market_group_id") @Index(where: .notNull) var marketGroupID: UInt32?
    @Column("is_published") @IndexFilter("byFlag", .isTrue) var isPublished: Bool
}

@Suite("Macro: partial index")
struct PartialIndexMacroTests {
    private static func index(_ name: String) -> TableIndex<PartialMacroRow>? {
        PartialMacroRow.descriptor.indexes.first { $0.resolvedName == name }
    }

    @Test("@Index(where:) gives a condition on its own column")
    func conditionOnOwnColumn() throws {
        let index = try #require(Self.index("idx_partialMacroRows_market_group_id"))
        #expect(index.predicates == [IndexPredicate(column: "market_group_id", condition: .notNull)])
    }

    @Test("@IndexFilter gives a condition on its own column to another index")
    func conditionOnForeignIndex() throws {
        let index = try #require(Self.index("byFlag"))
        #expect(index.columns.map(\.name) == ["id"])
        #expect(index.predicates == [IndexPredicate(column: "is_published", condition: .isTrue)])
    }

    @Test("an index without condition marks stays full")
    func plainIndexHasNoPredicates() throws {
        #expect(TypeInfo.descriptor.indexes.allSatisfy { $0.predicates.isEmpty })
    }
}
