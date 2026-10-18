//
//  ProjectionTests.swift
//  LiteRowTests
//

import Foundation
import Testing
@testable import LiteRow

/// A list row: columns from three tables, with names instead of positions.
@Projection
struct TypeListItem {
    var id: UInt32
    var name: String
    var groupName: String
    /// From a `LEFT JOIN`: the column is not optional in the schema, but the field must be,
    /// because optionality belongs to the row here, not to the column.
    var iconFile: String?
}

/// The same projection, but with whole tables.
@Projection
struct ShipRow {
    @Embedded var type: TypeInfo
    var groupName: String
    @Embedded var icon: AuxIcon?
}

@Suite("Projection into a named type")
struct ProjectionTests {
    @Test("width is computed from the property list")
    func width() {
        #expect(TypeListItem.width == 4)
        // A table field takes as many columns as the table itself.
        #expect(ShipRow.width == TypeInfo.width + 1 + AuxIcon.width)
    }

    @Test("SELECT column order follows property order")
    func projectionOrder() {
        let sql = TypeInfo.all()
            .join(TypeGroup.self) { type, group in type.groupID == group.id }
            .select { type, group in
                TypeListItem.projection(
                    id: type.id,
                    name: type.name,
                    groupName: group.name,
                    iconFile: type.name
                )
            }
            .query().sql

        #expect(sql.hasPrefix(#"SELECT t0."typeID", t0."typeName", t1."groupName", t0."typeName" FROM"#), "\(sql)")
    }

    @Test("a table field expands into its columns")
    func embeddedExpandsToColumns() {
        let sql = TypeInfo.all()
            .join(TypeGroup.self) { type, group in type.groupID == group.id }
            .select { type, group in
                EmbeddedOnly.projection(type: type, groupName: group.name)
            }
            .query().sql

        #expect(sql.hasPrefix(#"SELECT t0."typeID", t0."typeName", t0."groupID", t1."groupName" FROM"#), "\(sql)")
    }

    @Test("rows are decoded by field name")
    func decodesRows() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)
        let database = try Database(
            main: .memory(name: fixture.name),
            attached: [.aux: .memory(name: icons.name)]
        )

        let withGroup = TypeInfo.all().join(TypeGroup.self) { type, group in type.groupID == group.id }
        let withIcon = withGroup.leftJoin(AuxIcon.self) { type, _, icon in icon.typeID == type.id }
        let query = withIcon
            .select { type, group, icon in
                TypeListItem.projection(
                    id: type.id,
                    name: type.name,
                    groupName: group.name,
                    iconFile: icon.path
                )
            }
            .order(by: { type, _, _ in type.id })
            .query()

        let rows = try await database.read { reader in try reader.fetchAll(query) }

        #expect(rows.map(\.name) == ["Rifter", "Punisher", "Raven"])
        #expect(rows.map(\.groupName) == ["Frigate", "Frigate", "Battleship"])
        // A missed `LEFT JOIN` arrives as `nil`: the projection has no column, not an empty string.
        #expect(rows.map(\.iconFile) == ["rifter.png", nil, "raven.png"])
        withExtendedLifetime((fixture, icons)) {}
    }

    @Test("a table field decodes whole; a missed LEFT JOIN gives nil")
    func decodesEmbedded() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)
        let database = try Database(
            main: .memory(name: fixture.name),
            attached: [.aux: .memory(name: icons.name)]
        )

        let withGroup = TypeInfo.all().join(TypeGroup.self) { type, group in type.groupID == group.id }
        let withIcon = withGroup.leftJoin(AuxIcon.self) { type, _, icon in icon.typeID == type.id }
        let query = withIcon
            .select { type, group, icon in
                ShipRow.projection(type: type, groupName: group.name, icon: icon)
            }
            .order(by: { type, _, _ in type.id })
            .query()

        let rows = try await database.read { reader in try reader.fetchAll(query) }

        #expect(rows.map(\.type.name) == ["Rifter", "Punisher", "Raven"])
        #expect(rows.map(\.groupName) == ["Frigate", "Frigate", "Battleship"])
        #expect(rows.map { $0.icon?.path } == ["rifter.png", nil, "raven.png"])
        withExtendedLifetime((fixture, icons)) {}
    }
}

/// A projection without a single expression: just a table and a column.
@Projection
struct EmbeddedOnly {
    @Embedded var type: TypeInfo
    var groupName: String
}
