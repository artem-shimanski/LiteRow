//
//  InListTests.swift
//  LiteRowTests
//

import Testing

@testable import LiteRow

@Suite("IN over a list of values")
struct InListTests {
    @Test("text: the list expands into placeholders")
    func rendersPlaceholders() {
        let query = TypeInfo.all()
            .filter { type in type.id.in([1, 2, 3]) }
            .query()

        #expect(query.sql == #"""
            SELECT * FROM "main"."invTypes" AS t0 WHERE t0."typeID" IN (?, ?, ?)
            """#)
        #expect(query.bindings == [.integer(1), .integer(2), .integer(3)])
    }

    @Test("text: NOT IN")
    func rendersNotIn() {
        let query = TypeInfo.all()
            .filter { type in type.groupID.notIn([25]) }
            .query()

        #expect(query.sql.contains(#"t0."groupID" NOT IN (?)"#))
        #expect(query.bindings == [.integer(25)])
    }

    @Test("list values land on the positions of their `?` between neighbouring clauses")
    func bindsListInRenderOrder() {
        // The list is the only node that writes several parameters in one call, so the point is that
        // neighbouring clauses do not shift: list values sit between the WHERE value and the LIMIT value.
        let query = TypeInfo.all()
            .filter { type in type.name.like("R%") && type.groupID.in([25, 27]) }
            .limit(5)
            .query()

        #expect(query.bindings == [
            .text("R%"),        // WHERE, left half
            .integer(25),       // list
            .integer(27),
            .integer(5),        // LIMIT
        ])
    }

    @Test("an empty list is `IN ()`")
    func rendersEmptyList() {
        // Standard SQL forbids `IN ()`, SQLite allows it as an extension with the right semantics:
        // `IN ()` is false, `NOT IN ()` is true, even with NULL on the left. So there is no special case.
        let query = TypeInfo.all()
            .filter { type in type.id.in([]) }
            .query()

        #expect(query.sql.contains(#"t0."typeID" IN ()"#))
        #expect(query.bindings.isEmpty)
    }

    @Test("selecting by a list of keys")
    func fetchesRowsFromList() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let names = try await database.read { reader in
            let query = TypeInfo.all()
                .filter { type in type.id.in([1, 3]) }
                .order(by: { type in type.id })
                .query()
            return try reader.fetchAll(query).map(\.name)
        }

        #expect(names == ["Rifter", "Raven"])
        withExtendedLifetime(fixture) {}
    }

    @Test("an empty list selects nothing, an empty NOT IN selects everything")
    func fetchesWithEmptyList() async throws {
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let (included, excluded) = try await database.read { reader in
            let empty = TypeInfo.all()
                .filter { type in type.id.in([]) }
                .query()
            let notEmpty = TypeInfo.all()
                .filter { type in type.id.notIn([]) }
                .query()
            return (try reader.fetchAll(empty).count, try reader.fetchAll(notEmpty).count)
        }

        #expect(included == 0)
        #expect(excluded == 3)
        withExtendedLifetime(fixture) {}
    }

    @Test("a list of typed keys")
    func fetchesByTypedKeys() async throws {
        // List values are declared as `Value.Base`, so a `RawRepresentable` key arrives as its own type,
        // not a raw number, and `TypeID` cannot be mixed up with `AttributeID`.
        let fixture = try MemoryDatabaseFixture(sql: TestSchema.sql)
        let database = try Database(main: .memory(name: fixture.name), attached: [:])

        let values = try await database.read { reader in
            let query = TypeAttribute.all()
                .filter { attribute in
                    attribute.typeID.in([TypeID(rawValue: 1)]) && attribute.attributeID.in([AttributeID(rawValue: 4), AttributeID(rawValue: 9)])
                }
                .order(by: { attribute in attribute.value })
                .query()
            return try reader.fetchAll(query).map(\.value)
        }

        #expect(values == [350.0, 1200.0])
        withExtendedLifetime(fixture) {}
    }
}
