//
//  SchemaOverrideTests.swift
//  LiteRowTests
//

import Foundation
import Testing
@testable import LiteRow

/// A second copy of the same tables, attached under its own name.
///
/// This is why `in:` exists: the model declares its schema once, but here there are two,
/// and the query has to pick the copy.
extension DatabaseFile {
    static let mirror = DatabaseFile(schemaName: "mirror")
}

@Suite("Schema set on the query")
struct SchemaOverrideTests {
    /// The same tables as in `TestSchema` but with different values, so you can tell
    /// which copy a row actually came from.
    static let mirrorSQL = """
        CREATE TABLE invTypes (
            typeID INTEGER PRIMARY KEY,
            typeName TEXT NOT NULL,
            groupID INTEGER NOT NULL
        );
        INSERT INTO invTypes VALUES (1, 'Рифтер', 25), (3, 'Ворон', 27);

        CREATE TABLE eveIcons (
            iconID INTEGER PRIMARY KEY,
            typeID INTEGER NOT NULL,
            iconFile TEXT NOT NULL
        );
        INSERT INTO eveIcons VALUES (100, 1, 'rifter@2x.png'), (101, 3, 'raven@2x.png');
        """

    @Test("without an argument the schema stays as declared in @Table")
    func defaultsToDeclaredSchema() {
        #expect(AuxIcon.all().query().sql == #"SELECT * FROM "aux"."eveIcons" AS t0"#)
        #expect(TypeInfo.all().query().sql == #"SELECT * FROM "main"."invTypes" AS t0"#)
    }

    @Test("all(in:) changes the source schema")
    func overridesSourceSchema() {
        #expect(AuxIcon.all(in: .mirror).query().sql == #"SELECT * FROM "mirror"."eveIcons" AS t0"#)
    }

    @Test("join(in:) changes the schema of the joined table only")
    func overridesJoinedSchema() {
        let sql = TypeInfo.all()
            .join(AuxIcon.self, in: .mirror) { type, icon in icon.typeID == type.id }
            .query().sql
        #expect(sql == #"SELECT * FROM "main"."invTypes" AS t0 JOIN "mirror"."eveIcons" AS t1 ON t1."typeID" = t0."typeID""#)
    }

    @Test("the source schema survives a projection")
    func overrideSurvivesProjection() {
        // Regression: the schema is a builder field, and every method that rebuilds the builder
        // (`select`, `count`, `selectKey`, `join`) must carry it over.
        #expect(AuxIcon.all(in: .mirror).count().query().sql.contains(#""mirror"."eveIcons""#))
        #expect(AuxIcon.all(in: .mirror).select { $0.path }.query().sql.contains(#""mirror"."eveIcons""#))
        #expect(AuxIcon.all(in: .mirror).select { $0 }.query().sql.contains(#""mirror"."eveIcons""#))
        #expect(TypeInfo.all(in: .mirror).selectKey().query().sql.contains(#""mirror"."invTypes""#))

        let joined = AuxIcon.all(in: .mirror)
            .join(TypeInfo.self) { icon, type in type.id == icon.typeID }
        #expect(joined.query().sql.contains(#"FROM "mirror"."eveIcons""#))
    }

    @Test("rows are read from the given schema, not the declared one")
    func readsFromOverriddenSchema() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)
        let mirror = try MemoryDatabaseFixture(sql: Self.mirrorSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: icons.name), .mirror: .memory(name: mirror.name)]
        )

        let (declared, overridden) = try await database.read { reader -> ([String], [String]) in
            let byDefault = try reader.fetchAll(AuxIcon.all().order(by: { $0.id }).query()).map(\.path)
            let byOverride = try reader.fetchAll(AuxIcon.all(in: .mirror).order(by: { $0.id }).query()).map(\.path)
            return (byDefault, byOverride)
        }

        #expect(declared == ["rifter.png", "raven.png"])
        #expect(overridden == ["rifter@2x.png", "raven@2x.png"])
        withExtendedLifetime((main, icons, mirror)) {}
    }

    @Test("one model joins a query from two schemas at once")
    func joinsTwoCopiesOfTheSameTable() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let icons = try MemoryDatabaseFixture(sql: TestSchema.iconsSQL)
        let mirror = try MemoryDatabaseFixture(sql: Self.mirrorSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.aux: .memory(name: icons.name), .mirror: .memory(name: mirror.name)]
        )

        let rows = try await database.read { reader -> [String] in
            // One join per expression: growing the pack and unpacking it in the closure
            // in one chain hits an open type-checker bug.
            let withIcon = TypeInfo.all()
                .join(AuxIcon.self) { type, icon in icon.typeID == type.id }
            let withRetina = withIcon
                .join(AuxIcon.self, in: .mirror) { type, _, retina in retina.typeID == type.id }
            let query = withRetina.order(by: { type, _, _ in type.id }).query()
            return try reader.fetchAll(query).map { "\($0.left.right.path)|\($0.right.path)" }
        }

        #expect(rows == ["rifter.png|rifter@2x.png", "raven.png|raven@2x.png"])
        withExtendedLifetime((main, icons, mirror)) {}
    }

    @Test("lookup by key accepts a schema too")
    func findsByKeyInOverriddenSchema() async throws {
        let main = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let mirror = try MemoryDatabaseFixture(sql: Self.mirrorSQL)

        let database = try Database(
            main: .memory(name: main.name),
            attached: [.mirror: .memory(name: mirror.name)]
        )

        let (declared, overridden) = try await database.read { reader -> (String?, String?) in
            let byDefault = try reader.fetchOne(TypeInfo.self, key: 1)?.name
            let byOverride = try reader.fetchOne(TypeInfo.self, key: 1, in: .mirror)?.name
            return (byDefault, byOverride)
        }

        #expect(declared == "Rifter")
        #expect(overridden == "Рифтер")
        withExtendedLifetime((main, mirror)) {}
    }
}
